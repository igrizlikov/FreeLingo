//! FreeLingo 0.6.13 translation engine. A private bundled llama.cpp server runs
//! exclusively on localhost; models are downloaded separately by the AppKit UI.
use serde_json::{json, Value};
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hash, Hasher};
use std::sync::atomic::{AtomicU64, Ordering};
use std::fs::{self, File};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub type Completion = extern "C" fn(*mut c_char, c_int, *mut c_void);

struct Backend {
    model: PathBuf,
    child: Child,
    port: u16,
    token: String,
}
static BACKEND: OnceLock<Mutex<Option<Backend>>> = OnceLock::new();
static TRACE_HASHER: OnceLock<RandomState> = OnceLock::new();
static TRACE_SESSION: OnceLock<String> = OnceLock::new();
static TRACE_COUNTER: AtomicU64 = AtomicU64::new(0);
fn backend() -> &'static Mutex<Option<Backend>> {
    BACKEND.get_or_init(|| Mutex::new(None))
}

fn c_arg(ptr: *const c_char) -> String {
    if ptr.is_null() { return String::new(); }
    unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
}

pub fn system_prompt(target: &str, operation: &str) -> String {
    let lang = match target {
        "ru" => "Russian", "en" => "English (American)",
        "fi" => "Finnish", "de" => "German", "fr" => "French",
        "es" => "Spanish", "it" => "Italian", "ja" => "Japanese",
        "zh" => "Chinese", _ => "Russian",
    };
    if operation == "rewrite" {
        format!("You are a meticulous native-language editor. Improve the supplied text in {lang}. Fix grammar, spelling, word choice and awkward phrases. Preserve ALL facts, numbers, people, relationships, tense, meaning, paragraphs and names. Return only the improved text, never an explanation. /no_think")
    } else {
        let ru = if target == "ru" {
            " For English-to-Russian translation: use natural modern literary Russian, not English word order or literal calques. Russian kinship terms, plurals and numbers must match the source precisely. Translate professions as occupations (a nurse = медсестра), preserve each individual and their relationships, and render idioms naturally (have a good time = прекрасно проводить время). Example title: My Wonderful Family = Моя замечательная семья. Do not use Chinese, Japanese or untranslated English words except proper names."
        } else { "" };
        format!("You are an exact, fluent professional translator. Your task is to translate the ENTIRE user text into {lang}. Preserve every person, numerical quantity, plural, profession, event, tense, negation, and meaning; never summarize or omit. Keep paragraph boundaries, titles, quotations, and original tone. Choose idiomatic expressions in the target language, not word-by-word substitutions.{ru} Return ONLY the finished translation in the target language, without notes, markdown wrappers, reasoning or an introduction. /no_think")
    }
}

// Use paragraph/sentence-sized requests. A full multi-page document cannot fit
// inside a 4096-token context window and used to lose details or truncate output.
// Keep all boundaries on UTF-8 character boundaries.
fn chunk_boundary(text: &str, max: usize) -> usize {
    if text.len() <= max { return text.len(); }
    let mut last_char = 0;
    let mut whitespace = 0;
    let mut sentence = 0;
    for (idx, ch) in text.char_indices() {
        if idx + ch.len_utf8() > max { break; }
        last_char = idx + ch.len_utf8();
        if ch.is_whitespace() { whitespace = last_char; }
        if idx >= max / 2 && matches!(ch, '.' | '!' | '?' | ';' | '。' | '！' | '？') {
            sentence = last_char;
        }
    }
    if sentence > 0 { sentence } else if whitespace > 0 { whitespace } else { last_char }
}

fn split_long_line(text: &str, max: usize) -> Vec<String> {
    let mut remaining = text.trim();
    let mut result = Vec::new();
    while !remaining.is_empty() {
        let end = chunk_boundary(remaining, max);
        if end == 0 { break; }
        let part = remaining[..end].trim();
        if !part.is_empty() { result.push(part.to_owned()); }
        remaining = remaining[end..].trim_start();
    }
    result
}

fn has_cjk(text: &str) -> bool {
    text.chars().any(|c| matches!(c as u32,
        0x3400..=0x9FFF | 0xF900..=0xFAFF | 0x3040..=0x30FF))
}

// Lightweight post-generation guard. This does NOT prove translation quality;
// it catches obvious language leakage and a few high-impact factual regressions
// seen in real English->Russian translation samples. Reject rather than silently
// accepting a broken translation. A human must still judge fluency/accuracy.
fn quality_issue(source: &str, result: &str, target: &str) -> Option<&'static str> {
    if result.trim().is_empty() { return Some("Пустой ответ модели"); }
    if target != "ru" { return None; }
    if has_cjk(result) { return Some("Посторонние иероглифы в русском переводе"); }
    let cyrillic = result.chars().filter(|c| matches!(*c as u32, 0x0400..=0x052F)).count();
    let latin = result.chars().filter(|c| c.is_ascii_alphabetic()).count();
    if source.len() > 55 && cyrillic + latin > 30 && cyrillic * 100 < (cyrillic + latin) * 60 {
        return Some("Ответ преимущественно не на русском языке");
    }
    let en = source.to_ascii_lowercase();
    let ru = result.to_lowercase();
    // Factual checks are applied only to explicit source phrases, not to
    // arbitrary sentences or other language pairs.
    if en.contains("two brothers") &&
       !(ru.contains("брата") || ru.contains("братьев") || ru.contains("братьями")) {
        return Some("Потеряно множественное число: two brothers");
    }
    if en.contains("mother is a nurse") && !ru.contains("медсестр") {
        return Some("Потеряна профессия матери: nurse");
    }
    None
}

fn find_server() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| format!("Не удалось найти FreeLingo: {e}"))?;
    let sibling = exe.parent().unwrap_or(Path::new("/")).join("llama-server");
    if !sibling.is_file() {
        return Err("В пакете FreeLingo отсутствует llama-server. Требуется сборка с BUILD_LLAMA=1.".into());
    }
    Ok(sibling)
}

fn random_token() -> Result<String, String> {
    let mut random = [0_u8; 24];
    File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut random))
        .map_err(|e| format!("Ошибка получения случайного ключа: {e}"))?;
    Ok(random.iter().map(|v| format!("{v:02x}")).collect())
}

fn unused_port() -> Result<u16, String> {
    let socket = TcpListener::bind(("127.0.0.1", 0))
        .map_err(|e| format!("Нет свободного локального порта: {e}"))?;
    socket.local_addr().map(|addr| addr.port()).map_err(|e| e.to_string())
}

fn curl_request(url: &str, token: &str, body: Option<&str>, secs: &str) -> Result<Value, String> {
    let mut command = Command::new("/usr/bin/curl");
    command.args(["--silent", "--show-error", "--fail-with-body", "--noproxy", "*",
        "--connect-timeout", "2", "--max-time", secs, "--header", "Content-Type: application/json",
        "--header", &format!("Authorization: Bearer {token}")]);
    if body.is_some() { command.args(["--request", "POST", "--data-binary", "@-"]); }
    let mut child = command.arg(url).stdin(if body.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped()).stderr(Stdio::piped())
        .spawn().map_err(|e| format!("Не удалось запустить системный HTTP-клиент: {e}"))?;
    if let Some(text) = body {
        child.stdin.take().ok_or("Не удалось открыть stdin curl")?
            .write_all(text.as_bytes()).map_err(|e| format!("Ошибка отправки текста: {e}"))?;
    }
    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let body = String::from_utf8_lossy(&output.stdout);
        return Err(format!("Локальная модель недоступна: {} {}", stderr.trim(), body.trim().chars().take(250).collect::<String>()));
    }
    serde_json::from_slice(&output.stdout).map_err(|e| format!("Неверный ответ движка: {e}"))
}

fn start_server(model: &Path) -> Result<Backend, String> {
    if !model.is_file() || model.extension().and_then(|s| s.to_str()) != Some("gguf") {
        return Err("Модель не скачана. Открой «Модели» и установи GGUF-модель.".into());
    }
    let server = find_server()?;
    let port = unused_port()?;
    let token = random_token()?;
    let support = model.parent().unwrap_or(Path::new("/"));
    let log_dir = support.parent().unwrap_or(support).join("Logs");
    let _ = fs::create_dir_all(&log_dir);
    let log = File::create(log_dir.join("llama-server.log")).ok();
    let mut cmd = Command::new(server);
    cmd.arg("--model").arg(model)
        .args(["--host", "127.0.0.1", "--port", &port.to_string(),
               "--ctx-size", "6144", "--n-gpu-layers", "99", "--jinja", "--no-webui", "--alias", "freelingo", "--api-key", &token]);
    cmd.stdin(Stdio::null()).stdout(Stdio::null());
    if let Some(f) = log { cmd.stderr(Stdio::from(f)); } else { cmd.stderr(Stdio::null()); }
    let mut child = cmd.spawn().map_err(|e| format!("Не удалось запустить llama.cpp: {e}"))?;
    let health = format!("http://127.0.0.1:{port}/health");
    let deadline = Instant::now() + Duration::from_secs(95);
    while Instant::now() < deadline {
        if let Ok(Some(exit)) = child.try_wait() {
            return Err(format!("Движок llama.cpp завершился (код {exit}). См. Logs/llama-server.log"));
        }
        if let Ok(response) = curl_request(&health, &token, None, "2") {
            if response.get("status").and_then(Value::as_str) == Some("ok") {
                return Ok(Backend { model: model.to_owned(), child, port, token });
            }
        }
        thread::sleep(Duration::from_millis(400));
    }
    let _ = child.kill();
    let _ = child.wait();
    Err("Не удалось загрузить модель за 95 секунд. См. Logs/llama-server.log".into())
}

/// Hy-MT2 GGUF is a translation-only model, not a general editor.
/// Keep the original Qwen branch for rewriting and other target languages.
fn translate_gemma_model(model: &Path) -> bool {
    model.file_name().and_then(|s| s.to_str())
        .map(|s| s.to_ascii_lowercase().starts_with("translategemma-"))
        .unwrap_or(false)
}

// A per-process keyed SipHash prevents offline guessing of common source snippets
// from the log. Its secret key is never written to disk; hashes are comparable
// ONLY during one FreeLingo process, not across app restarts.
fn private_fingerprint(text: &str) -> String {
    let mut hasher = TRACE_HASHER.get_or_init(RandomState::new).build_hasher();
    text.hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

fn trace_session() -> &'static str {
    TRACE_SESSION.get_or_init(|| random_token()
        .map(|s| s.chars().take(12).collect())
        .unwrap_or_else(|_| format!("pid{}", std::process::id())))
}

fn trace_language(code: &str) -> &'static str {
    match code { "ru" => "ru", "en" => "en", "fr" => "fr", "it" => "it",
                 "zh" => "zh", "de" => "de", "fi" => "fi", "es" => "es",
                 "ja" => "ja", _ => "unknown" }
}

fn trace_origin(origin: &str) -> &'static str {
    match origin { "main" => "main", "hotkey" => "hotkey", "hotkey_clipboard" => "hotkey_clipboard", "ab" => "ab",
                   "ocr" => "ocr", "clipboard" => "clipboard", _ => "unknown" }
}

// The diagnostic log holds ONLY metadata: no text, translated results, full
// paths, prompts, HTTP bodies or user-defined strings. Do not log errors from
// external services because they can contain private input excerpts.
struct TranslationTrace {
    id: u64,
    origin: &'static str,
    raw_hash: String,
    source_hash: String,
    content_hash: String,
    raw_chars: usize,
    chars: usize,
    paragraphs: usize,
}
impl TranslationTrace {
    fn new(source: &str, origin: &str) -> Self {
        let normalized = normalized_translation_source(source);
        Self {
            id: TRACE_COUNTER.fetch_add(1, Ordering::Relaxed) + 1,
            origin: trace_origin(origin),
            raw_hash: private_fingerprint(source),
            source_hash: private_fingerprint(&normalized),
            // Ignore whitespace to determine whether flattened AX text is the
            // same content as paragraph-preserving clipboard text.
            content_hash: private_fingerprint(&normalized.chars().filter(|c| !c.is_whitespace()).collect::<String>()),
            raw_chars: source.chars().count(),
            chars: normalized.chars().count(),
            paragraphs: normalized.split('\n').count(),
        }
    }
    fn line(&self, model: &Path, event: &str, detail: &str) -> String {
        let seconds = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
        let name = model.file_name().and_then(|x| x.to_str()).unwrap_or("unknown");
        // Names are fixed identifiers from our embedded model catalog.
        let safe_filename = name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'));
        let name = if safe_filename && (name.starts_with("Hy-MT2") ||
            name.starts_with("translategemma-") || name.starts_with("Qwen3-")) { name } else { "unknown" };
        format!("{seconds} session={} request_id={} origin={} model={} event={} raw_hash={} source_hash={} content_hash={} raw_chars={} chars={} lines={} {}\n",
            trace_session(), self.id, self.origin, name, event, self.raw_hash, self.source_hash, self.content_hash,
            self.raw_chars, self.chars, self.paragraphs, detail)
    }
    fn log(&self, model: &Path, event: &str, detail: &str) {
        let Some(log_dir) = model.parent().and_then(Path::parent).map(|p| p.join("Logs")) else { return; };
        if fs::create_dir_all(&log_dir).is_err() { return; }
        if let Ok(mut file) = File::options().create(true).append(true)
            .open(log_dir.join("translation-diagnostics.log")) {
            let _ = file.write_all(self.line(model, event, detail).as_bytes());
        }
    }
}

fn normalized_translation_source(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\r', "\n").trim().to_owned()
}

fn translation_target(target: &str) -> &str {
    target.rsplit_once('>').map(|(_, t)| t).unwrap_or(target)
}

fn gemma_language_codes(target: &str) -> Result<(&str, &str), String> {
    let Some((source, to)) = target.split_once('>') else {
        return Err("TranslateGemma: нужен определённый исходный язык. Выдели более длинный фрагмент.".into());
    };
    let supported = ["ru", "en", "zh", "fr", "it"];
    if !supported.contains(&source) || !supported.contains(&to) || source == to {
        return Err("TranslateGemma: выбери разные языки из русского, английского, китайского, французского и итальянского.".into());
    }
    Ok((source, to))
}

fn hy_mt2_model(model: &Path) -> bool {
    model.file_name().and_then(|s| s.to_str())
        .map(|s| s.to_ascii_lowercase().starts_with("hy-mt2-"))
        .unwrap_or(false)
}

fn hy_target_name(target: &str) -> Option<&'static str> {
    match target {
        "ru" => Some("Russian"), "en" => Some("English"),
        "zh" => Some("Chinese"), "fr" => Some("French"),
        "it" => Some("Italian"), "de" => Some("German"),
        "es" => Some("Spanish"), "ja" => Some("Japanese"),
        _ => None,
    }
}

// As recommended in Tencent's Hy-MT2 model card: user-only instruction,
// without a generic system prompt or Qwen-specific /no_think directive.
// Hy-MT2 has an official instruction template for STYLE, separate from the
// default translation template. Do not ask the specialized translator to be a
// general-purpose rewriting agent, or append Qwen-specific thinking directives.
// Preserve the plain mode for repeatable side-by-side A/B comparisons.
fn hy_mt2_prompt(source: &str, target: &str, natural: bool, retry: bool) -> Result<String, String> {
    let language = hy_target_name(target).ok_or_else(||
        "Hy-MT2 не поддерживает выбранный язык в FreeLingo. Для этого языка выбери Qwen3.".to_string())?;
    if natural && target == "ru" {
        let style = if retry {
            "idiomatic, grammatically impeccable modern Russian suitable for a personal narrative; avoid literal English calques and unnatural verb-noun combinations; favor fluent native Russian sentence structure; faithfully preserve every fact, quantity, family relation, profession, tense and paragraph"
        } else {
            "natural, fluent contemporary Russian prose, suitable for a short personal story; idiomatic collocations rather than word-for-word calques; preserve the original meaning, facts, quantity, family relations, tone and paragraph structure"
        };
        return Ok(format!("Please translate the following text into {language}. Note that the translation style must strictly conform to [{style}]. Output only the translated result, without explanations:\n\n{source}"));
    }
    let advice = if retry {
        " Preserve all numbers, plurality, professions, names and relationships; use natural wording."
    } else { "" };
    Ok(format!("Translate the following text into {language}. Note that you should only output the translated result without any additional explanation:{advice}\n\n{source}"))
}

// Return per-model request data, separated from HTTP for deterministic tests.
fn make_payload(source: &str, target: &str, operation: &str, model: &Path, attempt: usize) -> Result<Value, String> {
    if translate_gemma_model(model) {
        if operation != "translate" && operation != "translate_natural" {
            return Err("TranslateGemma работает только в режиме перевода.".into());
        }
        let (source_code, target_code) = gemma_language_codes(target)?;
        // llama.cpp's specialized TranslateGemma adapter reads language codes
        // from chat_template_kwargs. The pinned llama.cpp tag must be smoke-tested.
        return Ok(json!({
            "model": "freelingo", "stream": false,
            "temperature": 0.0, "max_tokens": 2800,
            "chat_template_kwargs": {
                "source_lang_code": source_code,
                "target_lang_code": target_code
            },
            "messages": [{"role": "user", "content": source}]
        }));
    }
    if hy_mt2_model(model) {
        if operation != "translate" && operation != "translate_natural" {
            return Err("Hy-MT2 предназначена только для перевода. Для «Улучшить текст» выбери Qwen3.".to_owned());
        }
        let user_prompt = hy_mt2_prompt(source, target, operation == "translate_natural", attempt > 0)?;
        Ok(json!({
            "model": "freelingo", "stream": false,
            "temperature": 0.7, "top_p": 0.6, "top_k": 20,
            "repeat_penalty": 1.05, "max_tokens": 4096,
            "messages": [{"role": "user", "content": user_prompt}]
        }))
    } else {
        let mut instruction = system_prompt(target, operation);
        if operation == "translate_natural" && target == "ru" {
            instruction.push_str(" Write polished, natural Russian as a native editor would: no calques or awkward combinations of verbs and nouns. Preserve source meaning exactly, including numbers and relations. Do not add details.");
        }
        if attempt > 0 {
            instruction.push_str(" Carefully recheck counts, professions, family relations, and target language. Do not omit anything; produce the complete answer.");
        }
        Ok(json!({
            "model": "freelingo", "stream": false,
            "temperature": if attempt == 0 { 0.1 } else { 0.25 },
            "top_p": 0.85, "max_tokens": 1800,
            "chat_template_kwargs": { "enable_thinking": false },
            "messages": [
                { "role": "system", "content": instruction },
                { "role": "user", "content": source }
            ]
        }))
    }
}

fn plain_answer(value: &str) -> String {
    // Qwen3 may emit reasoning tags on engines where enable_thinking is ignored.
    let mut text = value.trim();
    if text.starts_with("<think>") {
        if let Some(end) = text.find("</think>") {
            text = text[end + "</think>".len()..].trim();
        }
    }
    text.to_owned()
}

fn request_chunk(session: &Backend, source: &str, target: &str, operation: &str, trace: &TranslationTrace, chunk_index: usize) -> Result<String, String> {
    let mut previous_error = "Модель вернула некачественный результат".to_owned();
    for attempt in 0..3 {
        let payload = make_payload(source, target, operation, &session.model, attempt)?;
        // Log the exact sampling parameters used by this attempt, not just UI preferences.
        let sampling = format!("chunk={} attempt={} temperature={} top_p={} top_k={} repeat_penalty={} max_tokens={}",
            chunk_index, attempt + 1,
            payload.get("temperature").map(|v| v.to_string()).unwrap_or_else(|| "default".into()),
            payload.get("top_p").map(|v| v.to_string()).unwrap_or_else(|| "default".into()),
            payload.get("top_k").map(|v| v.to_string()).unwrap_or_else(|| "default".into()),
            payload.get("repeat_penalty").map(|v| v.to_string()).unwrap_or_else(|| "default".into()),
            payload.get("max_tokens").map(|v| v.to_string()).unwrap_or_else(|| "default".into()));
        trace.log(&session.model, "sampling", &sampling);
        let answer = curl_request(&format!("http://127.0.0.1:{}/v1/chat/completions", session.port),
            &session.token, Some(&payload.to_string()), "240")?;
        if let Some(err) = answer.get("error") { return Err(err.to_string()); }
        let result = answer.pointer("/choices/0/message/content").and_then(Value::as_str)
            .ok_or("Движок не вернул текст")?;
        let result = plain_answer(result);
        let truncated = answer.pointer("/choices/0/finish_reason").and_then(Value::as_str) == Some("length");
        let problem = quality_issue(source, &result, translation_target(target));
        if !truncated && problem.is_none() { return Ok(result); }
        previous_error = if truncated { "Ответ модели обрезан".into() }
            else { problem.unwrap_or("Невозможно проверить ответ").to_owned() };
    }
    Err(format!("{previous_error}. Попробуй ещё раз или выбери другую модель."))
}

// Optional second pass: a general-purpose local model edits Hy-MT2's Russian
// translation WITH the original text in view. This is explicitly experimental:
// a language model cannot guarantee that every nuance or fact is preserved.
fn russian_editor_model(model: &Path) -> Option<PathBuf> {
    let folder = model.parent()?;
    ["Qwen3-8B-Q4_K_M.gguf", "Qwen3-4B-Q4_K_M.gguf"]
        .iter().map(|name| folder.join(name)).find(|p| p.is_file())
}

fn polish_payload(source: &str, draft: &str, retry: bool) -> Value {
    let extra = if retry { "Previous revision did not pass checks. Keep ALL source facts and remove no sentences." } else { "" };
    json!({
        "model": "freelingo", "stream": false, "temperature": 0.15,
        "top_p": 0.8, "max_tokens": 2500,
        "chat_template_kwargs": {"enable_thinking": false},
        "messages": [
            {"role": "system", "content": format!(
                "You are a native Russian literary copy editor and bilingual accuracy checker. The original is authoritative. Rewrite ONLY the Russian translation, correcting unnatural expressions, grammar, idioms and register. Preserve exact meaning, singular/plural, counts, chronology, kinship, named entities, titles, sentiment and every detail from the original. Do not translate again from scratch, add information, explain, summarize or change the original content. Output only polished Russian. {extra} /no_think")},
            {"role": "user", "content": format!("ORIGINAL TEXT:\n{source}\n\nRUSSIAN DRAFT TO POLISH:\n{draft}")}
        ]
    })
}

fn russian_polish(session: &Backend, source: &str, draft: &str) -> (String, &'static str) {
    // Never silently imply that an editor succeeded. Rejection reasons are
    // logged without the raw text (which may contain private clipboard data).
    let mut last_reason = "отклонён";
    for attempt in 0..2 {
        let payload = polish_payload(source, draft, attempt > 0);
        let response = curl_request(&format!("http://127.0.0.1:{}/v1/chat/completions", session.port),
            &session.token, Some(&payload.to_string()), "240");
        let Ok(response) = response else { last_reason = "ошибка_движка"; continue; };
        if response.pointer("/choices/0/finish_reason").and_then(Value::as_str) == Some("length") {
            last_reason = "ответ_обрезан";
            continue;
        }
        let Some(result) = response.pointer("/choices/0/message/content").and_then(Value::as_str) else {
            last_reason = "нет_ответа";
            continue;
        };
        let result = plain_answer(result);
        if quality_issue(source, &result, "ru").is_some() { last_reason = "потеря_фактов_или_языка"; continue; }
        if result.len() * 2 < draft.len() || result.len() > draft.len() * 2 {
            last_reason = "подозрительная_длина";
            continue;
        }
        if result.trim() == draft.trim() { return (draft.to_owned(), "без_изменений"); }
        return (result, "принято");
    }
    (draft.to_owned(), last_reason)
}

fn polish_document(session: &Backend, original: &str, translation: &str, trace: &TranslationTrace) -> String {
    let source_lines: Vec<&str> = original.split('\n').collect();
    let translated_lines: Vec<&str> = translation.split('\n').collect();
    if source_lines.len() != translated_lines.len() {
        trace.log(&session.model, "review", "status=skipped reason=paragraph_mismatch");
        return translation.to_owned();
    }
    source_lines.iter().zip(translated_lines.iter())
        .map(|(source, draft)| {
            if source.trim().is_empty() || draft.trim().is_empty() { return (*draft).to_owned(); }
            let (revision, reason) = russian_polish(session, source, draft);
            trace.log(&session.model, "review", &format!("status={}", match reason {
                "принято" => "accepted", "без_изменений" => "unchanged",
                "ошибка_движка" => "engine_error", "ответ_обрезан" => "truncated",
                "нет_ответа" => "no_response", "потеря_фактов_или_языка" => "quality_guard",
                "подозрительная_длина" => "length_guard", _ => "rejected" }));
            revision
        }).collect::<Vec<_>>().join("\n")
}

// Short stories need shared document context for kinship and idioms. Keep
// larger inputs chunked to stay within llama.cpp context limits; CJK token
// density is much higher than a Latin-alphabet character count suggests.
fn whole_document_mode(source: &str, operation: &str, model: &Path) -> bool {
    if !operation.starts_with("translate") || !(translate_gemma_model(model) || hy_mt2_model(model)) {
        return false;
    }
    let length = source.chars().count();
    length <= 3000 && (!has_cjk(source) || length <= 1300)
}

fn request_local(source: &str, target: &str, operation: &str, model: &str, source_language: &str, trace: &TranslationTrace) -> Result<String, String> {
    if source.trim().is_empty() { return Err("Нет текста для обработки".into()); }
    if source.len() > 50_000 { return Err("Максимальная длина запроса: 50 КБ".into()); }
    let path = PathBuf::from(model);
    if translate_gemma_model(&path) {
        gemma_language_codes(target)?;
        if operation != "translate" && operation != "translate_natural" {
            return Err("TranslateGemma не редактирует текст; выбери режим перевода.".into());
        }
    }
    // Validate model-specific capabilities before loading multi-GB GGUF into memory.
    if hy_mt2_model(&path) {
        if operation != "translate" && operation != "translate_natural" && operation != "translate_reviewed" {
            return Err("Hy-MT2 предназначена только для перевода. Для «Улучшить текст» выбери Qwen3.".to_owned());
        }
        hy_target_name(target).ok_or_else(||
            "Выбранный язык не поддерживается Hy-MT2 в этой версии FreeLingo. Переключись на Qwen3.".to_owned())?;
    }
    if operation == "translate_reviewed" && (!hy_mt2_model(&path) || target != "ru") {
        return Err("Литературная вычитка поддерживается только для Hy-MT2 → русский".into());
    }
    let editor_path = if operation == "translate_reviewed" {
        Some(russian_editor_model(&path).ok_or(
            "Для литературной вычитки нужна Qwen3 4B или 8B. Скачай её в разделе «Модели».".to_owned())?)
    } else { None };
    // Only ASCII language identifiers and validated operations enter the log.
    let pair = target.chars().filter(|c| c.is_ascii_lowercase() || *c == '>').collect::<String>();
    let mode = match operation { "translate" => "translate", "translate_natural" => "translate_natural",
        "translate_reviewed" => "translate_reviewed", "rewrite" => "rewrite", _ => "unknown" };
    trace.log(&path, "request", &format!("pair={} source_lang={} target_lang={} operation={}",
        pair, trace_language(source_language), trace_language(translation_target(target)), mode));
    let mut guard = backend().lock().map_err(|_| "Внутренняя ошибка движка".to_string())?;
    let restart = match guard.as_mut() {
        None => true,
        Some(previous) => previous.model != path || !matches!(previous.child.try_wait(), Ok(None)),
    };
    if restart {
        if let Some(mut old) = guard.take() { let _ = old.child.kill(); let _ = old.child.wait(); }
        *guard = Some(start_server(&path)?);
    }
    let session = guard.as_ref().ok_or("Движок не запущен")?;
    // Same canonical source handling for the main editor, popup (Cmd+4) and A/B.
    // Preserve paragraph breaks; normalize CRLF from browsers and text editors.
    let normalized_source = normalized_translation_source(source);
    let normalized_source = normalized_source.as_str();
    let translate_mode = if operation == "translate_reviewed" { "translate_natural" } else { operation };
    let short_specialized_document = whole_document_mode(normalized_source, operation, &path);
    let mut output = String::new();
    let expected_chunks = if short_specialized_document { 1 }
        else { normalized_source.split_inclusive('\n').map(|line| {
            let body = line.strip_suffix('\n').unwrap_or(line);
            if body.trim().is_empty() { 0 } else { split_long_line(body, 1100).len() }
        }).sum() };
    trace.log(&path, "layout", &format!("layout={} chunks={}",
        if short_specialized_document { "whole" } else { "chunked" }, expected_chunks));
    if short_specialized_document {
        // Whole-document context is essential to resolve kinship, chronology,
        // pronouns and idioms in a short story. This also eliminates separate
        // model invocations caused by hard line breaks in the source editor.
        output = request_chunk(session, normalized_source, target, translate_mode, trace, 1)?;
    } else {
        let mut chunk_index = 0;
        for line in normalized_source.split_inclusive('\n') {
        let body = line.strip_suffix('\n').unwrap_or(line);
        let separator = if line.ends_with('\n') { "\n" } else { "" };
        // Blank lines remain blank. Each translated unit is within the context limit.
        if !body.trim().is_empty() {
            let parts = split_long_line(body, 1100);
            for (index, part) in parts.iter().enumerate() {
                if index > 0 { output.push(' '); }
                chunk_index += 1;
                output.push_str(&request_chunk(session, part, target, translate_mode, trace, chunk_index)?);
            }
        }
        output.push_str(separator);
        }
    }
    if output.trim().is_empty() { return Err("Модель вернула пустой результат".into()); }
    trace.log(&path, "translation", &format!("status=success result_hash={} result_chars={}",
        private_fingerprint(&output), output.chars().count()));
    if let Some(editor_path) = editor_path {
        // Load only one big model at a time; replace Hy-MT2 with Qwen for review.
        if let Some(mut previous) = guard.take() {
            let _ = previous.child.kill(); let _ = previous.child.wait();
        }
        *guard = Some(start_server(&editor_path)?);
        let editor = guard.as_ref().ok_or("Редактор не запущен")?;
        let polished = polish_document(editor, source, &output, trace);
        trace.log(&path, "final", &format!("status=success result_hash={} result_chars={}",
            private_fingerprint(&polished), polished.chars().count()));
        return Ok(polished);
    }
    trace.log(&path, "final", &format!("status=success result_hash={} result_chars={}",
        private_fingerprint(&output), output.chars().count()));
    Ok(output)
}

/// Async ABI: callback on background thread; caller owns returned C string.
#[no_mangle]
pub extern "C" fn fl_work_async_diagnostic(text: *const c_char, target: *const c_char,
    operation: *const c_char, model: *const c_char, origin: *const c_char,
    source_language: *const c_char, done: Option<Completion>, context: *mut c_void) {
    let text = c_arg(text);
    let target = c_arg(target);
    let operation = c_arg(operation);
    let model = c_arg(model);
    let origin = c_arg(origin);
    let source_language = c_arg(source_language);
    // Instantiate the keyed source fingerprint before entering the worker.
    let trace = TranslationTrace::new(&text, &origin);
    let context_id = context as usize;
    thread::spawn(move || {
        let outcome = std::panic::catch_unwind(|| request_local(&text, &target, &operation, &model, &source_language, &trace))
            .unwrap_or_else(|_| Err("Ошибка локального движка".into()));
        let (result, ok) = match outcome { Ok(s) => (s, 1), Err(e) => (e, 0) };
        if ok == 0 { trace.log(Path::new(&model), "translation", "status=error"); }
        let ptr = CString::new(result.replace('\0', " ")).expect("NUL removed").into_raw();
        if let Some(callback) = done { callback(ptr, ok, context_id as *mut c_void); }
        else { fl_free_string(ptr); }
    });
}

// Retain the original C entry point for callers not yet providing provenance.
#[no_mangle]
pub extern "C" fn fl_work_async(text: *const c_char, target: *const c_char,
    operation: *const c_char, model: *const c_char,
    done: Option<Completion>, context: *mut c_void) {
    fl_work_async_diagnostic(text, target, operation, model,
        c"unknown".as_ptr(), c"unknown".as_ptr(), done, context);
}

#[no_mangle]
pub extern "C" fn fl_free_string(s: *mut c_char) {
    if !s.is_null() { unsafe { drop(CString::from_raw(s)); } }
}

/// Best-effort cleanup. Never block the UI if translation is still running.
#[no_mangle]
pub extern "C" fn fl_shutdown() {
    if let Ok(mut guard) = backend().try_lock() {
        if let Some(mut session) = guard.take() { let _ = session.child.kill(); let _ = session.child.wait(); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn whitespace_only_layout_differences_have_identical_content_hashes() {
        let main = TranslationTrace::new("English line 1\nEnglish line 2", "main");
        let hotkey = TranslationTrace::new("English line 1English line 2", "hotkey_clipboard");
        assert_ne!(main.source_hash, hotkey.source_hash);
        assert_eq!(main.content_hash, hotkey.content_hash);
        assert_eq!(hotkey.origin, "hotkey_clipboard");
        let model = Path::new("/Models/translategemma-12b-it-Q4_K_M.gguf");
        assert!(translate_gemma_model(model));
        assert!(make_payload("Hello!", "en>ru", "translate", model, 0).is_ok());
    }

    #[test] fn keyed_trace_fingerprint_is_stable_per_session_and_redacted() {
        let text = "My private story: two brothers and my mother.";
        let trace_main = TranslationTrace::new(text, "main");
        let trace_hotkey = TranslationTrace::new(text, "hotkey");
        assert_eq!(trace_main.source_hash, trace_hotkey.source_hash);
        assert_ne!(trace_main.id, trace_hotkey.id);
        assert_ne!(trace_main.raw_hash, private_fingerprint("a different text"));
        let line = trace_main.line(Path::new("/Models/translategemma-4b_Q4_K_M.gguf"),
            "request", "pair=en>ru operation=translate");
        assert!(line.contains("origin=main"));
        assert!(line.contains("request_id="));
        assert!(line.contains("source_hash="));
        assert!(!line.contains(text));
        assert!(!line.contains("/Models/"));
        assert_eq!(trace_origin("unexpected\ntrace=injected"), "unknown");
        assert_eq!(trace_language("en\nsource=injected"), "unknown");
    }
    #[test] fn fingerprint_normalizes_crlf_and_outer_spaces() {
        let raw_a = "  Hello\r\nworld!\r\n";
        let raw_b = "Hello\nworld!";
        let a = TranslationTrace::new(raw_a, "main");
        let b = TranslationTrace::new(raw_b, "hotkey");
        assert_eq!(a.source_hash, b.source_hash);
        assert_ne!(a.raw_hash, b.raw_hash);
        assert_eq!(a.chars, b.chars);
    }
    #[test] fn whole_document_context_for_short_specialized_texts() {
        let gemma = Path::new("/Models/translategemma-4b_Q4_K_M.gguf");
        let hy = Path::new("/Models/Hy-MT2-7B-Q4_K_M.gguf");
        let qwen = Path::new("/Models/Qwen3-4B-Q4_K_M.gguf");
        let family = "My Wonderful Family\nI have two brothers and one sister.\n\nWe love walking together.";
        assert!(whole_document_mode(family, "translate", gemma));
        assert!(whole_document_mode(family, "translate_natural", hy));
        assert!(!whole_document_mode(family, "rewrite", gemma));
        assert!(!whole_document_mode(family, "translate", qwen));
        assert!(!whole_document_mode(&"a".repeat(3001), "translate", gemma));
        assert!(whole_document_mode("你好。天气很好。", "translate", gemma));
        assert!(!whole_document_mode(&"中".repeat(1301), "translate", gemma));
    }
    #[test] fn gemma_requires_direction_and_uses_template_kwargs() {
        let model = Path::new("/Models/translategemma-4b_Q4_K_M.gguf");
        assert!(translate_gemma_model(model));
        let payload = make_payload("I have two brothers.", "en>ru", "translate", model, 0).unwrap();
        assert_eq!(payload["chat_template_kwargs"]["source_lang_code"], "en");
        assert_eq!(payload["chat_template_kwargs"]["target_lang_code"], "ru");
        assert_eq!(payload["messages"][0]["content"], "I have two brothers.");
        assert!(make_payload("hello", "ru", "translate", model, 0).is_err());
        assert!(make_payload("hello", "en>en", "translate", model, 0).is_err());
        assert!(make_payload("hello", "en>ru", "rewrite", model, 0).is_err());
        assert_eq!(translation_target("en>ru"), "ru");
    }

    #[test] fn polish_includes_original_and_translation() {
        let j = polish_payload("I have two brothers.", "У меня два брата.", false);
        let messages = j["messages"].as_array().unwrap();
        assert!(messages[1]["content"].as_str().unwrap().contains("I have two brothers."));
        assert!(messages[1]["content"].as_str().unwrap().contains("У меня два брата."));
        assert_eq!(j["chat_template_kwargs"]["enable_thinking"], false);
    }
    #[test] fn russian_editor_selects_existing_model() {
        let missing = russian_editor_model(Path::new("/nonexistent/Hy-MT2-7B-Q4_K_M.gguf"));
        assert!(missing.is_none());
    }
    #[test] fn language_prompt() { assert!(system_prompt("fi", "translate").contains("Finnish")); }
    #[test] fn improve_prompt() { assert!(system_prompt("en", "rewrite").contains("editor")); }
    #[test] fn prevent_qwen_reasoning() {
        assert_eq!(plain_answer("<think>Reasoning</think>   Привет"), "Привет");
    }
    #[test] fn hy_model_detection() {
        assert!(hy_mt2_model(Path::new("/Models/Hy-MT2-7B-Q4_K_M.gguf")));
        assert!(hy_mt2_model(Path::new("/Models/Hy-MT2-1.8B-Q4_K_M.gguf")));
        assert!(!hy_mt2_model(Path::new("/Models/Qwen3-4B-Q4_K_M.gguf")));
    }
    #[test] fn hy_language_targets() {
        for code in ["ru", "en", "zh", "fr", "it"] { assert!(hy_target_name(code).is_some()); }
        assert!(hy_target_name("fi").is_none());
    }
    #[test] fn hy_prompt_uses_user_only_and_official_sampling() {
        let model = Path::new("/Models/Hy-MT2-7B-Q4_K_M.gguf");
        let json = make_payload("My Wonderful Family", "ru", "translate", model, 0).unwrap();
        assert_eq!(json["temperature"], 0.7);
        assert_eq!(json["top_p"], 0.6);
        assert_eq!(json["top_k"], 20);
        assert_eq!(json["repeat_penalty"], 1.05);
        assert_eq!(json["messages"].as_array().unwrap().len(), 1);
        assert_eq!(json["messages"][0]["role"], "user");
        assert!(json["messages"][0]["content"].as_str().unwrap().contains("into Russian"));
        assert!(!json.to_string().contains("/no_think"));
    }
    #[test] fn natural_style_uses_official_hy_style_template() {
        let path = Path::new("/Models/Hy-MT2-7B-Q4_K_M.gguf");
        let natural = make_payload("I was born last.", "ru", "translate_natural", path, 0).unwrap();
        let content = natural["messages"][0]["content"].as_str().unwrap();
        assert!(content.contains("translation style must strictly conform"));
        assert!(content.contains("idiomatic collocations"));
        assert!(content.contains("facts, quantity, family relations"));
        assert_eq!(natural["messages"].as_array().unwrap().len(), 1);
        let ordinary = make_payload("I was born last.", "ru", "translate", path, 0).unwrap();
        assert_ne!(natural["messages"][0]["content"], ordinary["messages"][0]["content"]);
        assert!(!ordinary["messages"][0]["content"].as_str().unwrap().contains("style must strictly conform"));
    }
    #[test] fn natural_style_is_ignored_for_non_russian_targets() {
        let path = Path::new("/Models/Hy-MT2-7B-Q4_K_M.gguf");
        let j = make_payload("Bonjour!", "it", "translate_natural", path, 0).unwrap();
        assert!(j["messages"][0]["content"].as_str().unwrap().contains("into Italian"));
        assert!(!j["messages"][0]["content"].as_str().unwrap().contains("Russian prose"));
    }
    #[test] fn hy_rewrite_rejected() {
        assert!(make_payload("Привет", "ru", "rewrite", Path::new("Hy-MT2-7B-Q4_K_M.gguf"), 0).is_err());
    }
    #[test] fn qwen_payload_unchanged() {
        let j = make_payload("Hello", "ru", "translate", Path::new("Qwen3-4B-Q4_K_M.gguf"), 0).unwrap();
        assert_eq!(j["messages"].as_array().unwrap().len(), 2);
        assert_eq!(j["temperature"], 0.1);
    }
    #[test] fn unchanged_answer() { assert_eq!(plain_answer("  Привет  "), "Привет"); }
    #[test] fn split_preserves_word_boundaries() {
        let parts = split_long_line("Hello wonderful family. We are all happy here. Everyone is welcome.", 32);
        assert_eq!(parts.join(" "), "Hello wonderful family. We are all happy here. Everyone is welcome.");
    }
    #[test] fn split_unicode_never_breaks_codepoints() {
        let parts = split_long_line("Привет прекрасная семья. Мы вместе и счастливы. 好朋友", 23);
        assert_eq!(parts.join(" "), "Привет прекрасная семья. Мы вместе и счастливы. 好朋友");
    }
    #[test] fn detect_foreign_script_in_russian_output() {
        assert!(has_cjk("моя мама — 护士 в больнице"));
        assert!(!has_cjk("моя мама — медсестра в больнице"));
    }
    #[test] fn chinese_to_russian_must_not_leave_chinese() {
        assert_eq!(quality_issue("我的妈妈是一名护士。", "Моя мама — 护士.", "ru"),
            Some("Посторонние иероглифы в русском переводе"));
    }
    #[test] fn quality_catches_language_leakage() {
        assert_eq!(quality_issue("My mother is a nurse at a big hospital.",
            "Моя мама — 护士 в больнице.", "ru"),
            Some("Посторонние иероглифы в русском переводе"));
        assert!(quality_issue("Hello dear friend, I love this place, and every day I am very happy to be here!",
            "Hello dear friend, I love this place, and every day I am very happy to be here!", "ru").is_some());
    }
    #[test] fn quality_catches_missing_people() {
        let en = "I have two brothers and one sister. My mother is a nurse.";
        assert!(quality_issue(en, "У меня есть брат и сестра. Моя мама работает в больнице.", "ru").is_some());
        assert_eq!(quality_issue(en, "У меня два брата и сестра. Моя мама — медсестра.", "ru"), None);
    }
    #[test] fn quality_does_not_reject_rewrite() {
        assert_eq!(quality_issue("Улучшить русский текст", "Прекрасный текст.", "ru"), None);
    }
    #[test] fn enforce_plural_and_idiomatic_prompt() {
        let p = system_prompt("ru", "translate");
        assert!(p.contains("plural"));
        assert!(p.contains("idiomatic"));
    }
}
