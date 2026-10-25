//! FreeLingo 0.6.3 translation engine. A private bundled llama.cpp server runs
//! exclusively on localhost; models are downloaded separately by the AppKit UI.
use serde_json::{json, Value};
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::fs::{self, File};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

pub type Completion = extern "C" fn(*mut c_char, c_int, *mut c_void);

struct Backend {
    model: PathBuf,
    child: Child,
    port: u16,
    token: String,
}
static BACKEND: OnceLock<Mutex<Option<Backend>>> = OnceLock::new();
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
    if !has_cjk(source) && has_cjk(result) { return Some("Посторонние иероглифы в русском переводе"); }
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
               "--ctx-size", "6144", "--n-gpu-layers", "99", "--no-webui", "--alias", "freelingo", "--api-key", &token]);
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

fn request_chunk(session: &Backend, source: &str, target: &str, operation: &str) -> Result<String, String> {
    let mut previous_error = "Модель вернула некачественный результат".to_owned();
    for attempt in 0..3 {
        let mut instruction = system_prompt(target, operation);
        if attempt > 0 {
            instruction.push_str(" Carefully recheck counts, professions, family relations, and target language. Do not omit anything; produce the complete answer.");
        }
        let payload = json!({
            "model": "freelingo", "stream": false,
            "temperature": if attempt == 0 { 0.1 } else { 0.25 },
            "top_p": 0.85, "max_tokens": 1800,
            "chat_template_kwargs": { "enable_thinking": false },
            "messages": [
                { "role": "system", "content": instruction },
                { "role": "user", "content": source }
            ]
        });
        let answer = curl_request(&format!("http://127.0.0.1:{}/v1/chat/completions", session.port),
            &session.token, Some(&payload.to_string()), "240")?;
        if let Some(err) = answer.get("error") { return Err(err.to_string()); }
        let result = answer.pointer("/choices/0/message/content").and_then(Value::as_str)
            .ok_or("Движок не вернул текст")?;
        let result = plain_answer(result);
        let truncated = answer.pointer("/choices/0/finish_reason").and_then(Value::as_str) == Some("length");
        let problem = quality_issue(source, &result, target);
        if !truncated && problem.is_none() { return Ok(result); }
        previous_error = if truncated { "Ответ модели обрезан".into() }
            else { problem.unwrap_or("Невозможно проверить ответ").to_owned() };
    }
    Err(format!("{previous_error}. Попробуй ещё раз или выбери другую модель."))
}

fn request_local(source: &str, target: &str, operation: &str, model: &str) -> Result<String, String> {
    if source.trim().is_empty() { return Err("Нет текста для обработки".into()); }
    if source.len() > 50_000 { return Err("Максимальная длина запроса: 50 КБ".into()); }
    let path = PathBuf::from(model);
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
    let mut output = String::new();
    for line in source.split_inclusive('\n') {
        let body = line.strip_suffix('\n').unwrap_or(line);
        let separator = if line.ends_with('\n') { "\n" } else { "" };
        // Blank lines remain blank. Each translated unit is within the context limit.
        if !body.trim().is_empty() {
            let parts = split_long_line(body, 1100);
            for (index, part) in parts.iter().enumerate() {
                if index > 0 { output.push(' '); }
                output.push_str(&request_chunk(session, part, target, operation)?);
            }
        }
        output.push_str(separator);
    }
    if output.trim().is_empty() { return Err("Модель вернула пустой результат".into()); }
    Ok(output)
}

/// Async ABI: callback on background thread; caller owns returned C string.
#[no_mangle]
pub extern "C" fn fl_work_async(text: *const c_char, target: *const c_char,
    operation: *const c_char, model: *const c_char,
    done: Option<Completion>, context: *mut c_void) {
    let text = c_arg(text);
    let target = c_arg(target);
    let operation = c_arg(operation);
    let model = c_arg(model);
    let context_id = context as usize;
    thread::spawn(move || {
        let outcome = std::panic::catch_unwind(|| request_local(&text, &target, &operation, &model))
            .unwrap_or_else(|_| Err("Ошибка локального движка".into()));
        let (result, ok) = match outcome { Ok(s) => (s, 1), Err(e) => (e, 0) };
        let ptr = CString::new(result.replace('\0', " ")).expect("NUL removed").into_raw();
        if let Some(callback) = done { callback(ptr, ok, context_id as *mut c_void); }
        else { fl_free_string(ptr); }
    });
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
    #[test] fn language_prompt() { assert!(system_prompt("fi", "translate").contains("Finnish")); }
    #[test] fn improve_prompt() { assert!(system_prompt("en", "rewrite").contains("editor")); }
    #[test] fn prevent_qwen_reasoning() {
        assert_eq!(plain_answer("<think>Reasoning</think>   Привет"), "Привет");
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
