# FreeLingo 0.6.4 — исправление сборки

В native/ModelManager.inc исправлен вызов unsignedLongLongValue для NSString на поддерживаемый longLongValue с приведением к unsigned long long. Добавлен регрессионный тест в tests/check_release.py. Версия и номер сборки не меняются, так как предыдущая 0.6.4 не была опубликована.

Публикация: загрузить FreeLingo064fix.zip в корень репозитория; Publish FreeLingo signed update → Run workflow → source_zip: FreeLingo064fix.zip. CI macOS соберёт приложение, подпишет релиз и опубликует обновление Sparkle, если все этапы пройдут.
