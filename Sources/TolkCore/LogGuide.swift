// A human guide to tolk.log: every kind of line the app writes, grouped, with what it means and what to do.
// One source for three readers: Настройки → Журнал (explanations and the «Проблемы» filter), the README written
// next to the log files, and docs/journal.md in the repository (`tolk-cli --log-guide`).
import Foundation

public enum LogGuide {
    public enum Kind: String, Sendable {
        case normal     // routine work
        case note       // not an error, but explains why something did not happen
        case problem    // something went wrong
    }

    public enum Group: String, CaseIterable, Sendable {
        case translate, suggestShown, suggestSilent, suggestInsert, field, typing, model, server, capture, typeTranslate, style, app

        public var title: String {
            switch self {
            case .translate: "Перевод"
            case .suggestShown: "Подсказки: показ и принятие"
            case .suggestSilent: "Подсказки: почему не появилась"
            case .suggestInsert: "Подсказки: вставка по Tab"
            case .field: "Чтение поля ввода"
            case .typing: "Опечатки и эмодзи"
            case .model: "Модель подсказок (на этом Mac)"
            case .server: "Сервер перевода и его модели"
            case .capture: "Снимок экрана (⌥⇧S) и распознавание"
            case .typeTranslate: "Перевод при наборе"
            case .style: "Память стиля"
            case .app: "Программа в целом"
            }
        }

        public var about: String {
            switch self {
            case .translate: "Каждый перевод оставляет одну строку. Самого текста в журнале нет — только длины и времена."
            case .suggestShown: "Жизнь одной подсказки: показана, принята или спрятана."
            case .suggestSilent: "Вы остановились, а у курсора пусто. Эти строки говорят, на каком шаге всё закончилось."
            case .suggestInsert: "Перед вставкой Tolk перечитывает поле: если оно изменилось, вставлять опасно."
            case .field: "Tolk читает текст поля через «Универсальный доступ». Не каждая программа отдаёт его одинаково."
            case .typing: "Мгновенные подсказки без модели."
            case .model: "Запуск и остановка llama-server с моделью подсказок, скачивание файлов моделей."
            case .server: "Связь с домашним сервером (Ollama) и действия с его моделями."
            case .capture: "Выделение области экрана и распознавание текста на ней."
            case .typeTranslate: "Режим, в котором под полем показывается перевод вашего текста."
            case .style: "Примеры ваших сообщений, по которым подсказки подстраиваются под вас."
            case .app: "Запуск, настройки, питание, окна."
            }
        }
    }

    public struct Entry: Sendable {
        /// The line must contain every one of these (case-sensitive substrings).
        public let match: [String]
        public let group: Group
        public let kind: Kind
        /// Short name in plain words.
        public let title: String
        /// What it means.
        public let meaning: String
        /// What to do (nil = nothing, this is how it works).
        public let action: String?
        /// A sample line for the documentation.
        public let sample: String

        init(_ match: [String], _ group: Group, _ kind: Kind, _ title: String, _ meaning: String, action: String? = nil, sample: String) {
            self.match = match; self.group = group; self.kind = kind; self.title = title; self.meaning = meaning; self.action = action; self.sample = sample
        }
    }

    /// Specific entries first: the first match wins.
    public static let entries: [Entry] = [
        // MARK: Перевод
        Entry(["translate:", "FAILED"], .translate, .problem, "Перевод не удался",
              "Ни сервер, ни запасной перевод не дали результата. После «FAILED» — через сколько миллисекунд и почему.",
              action: "Проверьте «Настройки → Перевод → Сервер перевода → Проверить». Если сервер выключен, включите запасной перевод.",
              sample: "translate: popup FAILED in=120 after 4012 ms: Сервер перевода не ответил вовремя"),
        Entry(["translate:", "fallback("], .translate, .note, "Перевёл запасной переводчик",
              "Сервер не ответил, перевод сделал Google или Apple. В скобках — причина.",
              action: "Если это часто — проверьте сервер. Глоссарий и тон в запасном переводе не действуют.",
              sample: "translate: popup en→ru in=120 out=131 provider=Google route=web ms=640 fallback(сервер недоступен)"),
        Entry(["translate:", " cache"], .translate, .normal, "Перевод из кэша",
              "Этот текст уже переводился — ответ отдан мгновенно, модель не вызывалась.",
              sample: "translate: popup en→ru in=120 out=131 provider=Gemma route=home ms=0 cache"),
        Entry(["translate:"], .translate, .normal, "Перевод выполнен",
              "Откуда (popup — двойное ⌘C, reply — ответ, quick — быстрое действие, page — окно Tolk, image — фото), направление, длина текста (in) и ответа (out) в знаках, кто перевёл, каким путём (home — дома, remote — вне дома, web — интернет, device — на этом Mac) и за сколько миллисекунд. «warnings=N» — автопроверка нашла потерянное число или ссылку.",
              sample: "translate: popup en→ru in=120 out=131 provider=Gemma route=home ms=840"),
        Entry(["mask:"], .translate, .note, "Защита имён и ссылок не сработала с первого раза",
              "Tolk прячет от модели ссылки, почту и номера, чтобы она их не исказила. Модель потеряла метку — перевод повторён без защиты.",
              action: "Сверьте в таком переводе ссылки и цифры с оригиналом.",
              sample: "mask: placeholder lost/duplicated, retry without masking (2 entities: url,email)"),
        Entry(["editor: started by itself"], .translate, .normal, "Редактор запущен автоматически",
              "Текст похож на официальный (или в настройках выбрано «всегда») — готовый перевод сразу перечитывает редактор.",
              sample: "editor: started by itself (popup, 1068 chars)"),
        Entry(["documents:"], .translate, .normal, "Перевод документа",
              "editor — режим «Редактор после перевода», official — документ распознан как официальный, в конце — сколько абзацев редактор изменил.",
              sample: "documents: finished, editor changed 3 paragraph(s)"),
        Entry(["incremental:"], .translate, .normal, "Перевод по мере набора",
              "В окне Tolk переводится только изменившийся хвост текста; в конце — контрольный проход целиком.",
              sample: "incremental: full sent=6 chars=399"),
        Entry(["double Cmd+C: event tap was disabled"], .translate, .note, "Перехват ⌘C восстановлен",
              "Система временно отключила перехват клавиш (так бывает при зависании программы) — Tolk включил его снова.",
              sample: "double Cmd+C: event tap was disabled — re-enabled"),
        Entry(["double Cmd+C inside Tolk"], .translate, .normal, "Двойное ⌘C внутри Tolk пропущено",
              "В окнах самого Tolk двойное ⌘C перевод не открывает.", sample: "double Cmd+C inside Tolk (Перевод) — ignored"),
        Entry(["double Cmd+C:"], .translate, .normal, "Двойное ⌘C", "Вы дважды нажали ⌘C — открылось окно перевода. Число — длина выделенного текста.",
              sample: "double Cmd+C: 214 chars"),
        Entry(["translate clipboard:"], .translate, .normal, "Перевод буфера обмена", "Перевод запущен из меню для текста в буфере.", sample: "translate clipboard: 88 chars"),
        Entry(["reply:", "did not become frontmost"], .translate, .note, "Ответ не вставлен — оставлен в буфере",
              "Программа, в которую нужно было вставить ответ, не вышла на передний план. Перевод лежит в буфере обмена.",
              action: "Перейдите в чат и вставьте вручную (⌘V).", sample: "reply: Telegram did not become frontmost — left on the clipboard"),
        Entry(["reply"], .translate, .normal, "Окно ответа", "Открыто окно «Ответить», выбрана заготовка или ответ вставлен в чат.", sample: "reply inserted into Telegram"),
        Entry(["quick ", "failed"], .translate, .problem, "Быстрое действие не удалось",
              "«Перевести и заменить» или «Причесать» не получили ответ модели.", action: "Проверьте сервер перевода.",
              sample: "quick translate: failed: Сервер перевода не ответил вовремя"),
        Entry(["quick ", "no selection"], .translate, .note, "Быстрое действие: ничего не выделено",
              "Горячая клавиша нажата, но выделенного текста нет.", action: "Сначала выделите текст.", sample: "quick translate: no selection"),
        Entry(["quick ", "read-only"], .translate, .note, "Быстрое действие: поле нельзя менять",
              "Текст выделен там, где его нельзя заменить. Результат оставлен в буфере обмена.", action: "Вставьте его куда нужно (⌘V).",
              sample: "quick translate: focused field is read-only — result left on the clipboard"),
        Entry(["quick "], .translate, .normal, "Быстрое действие", "Выделенный текст переведён, причёсан или исправлена раскладка.", sample: "quick translate: Gemma → 96 chars, pasting"),

        // MARK: Подсказки: показ
        Entry(["autocomplete: shown"], .suggestShown, .normal, "Подсказка показана",
              "len — длина подсказки, ms — сколько думала модель, ctx — сколько знаков переписки она видела, app — программа. «(patient)» — показана после паузы. Остальное — где на экране стоит курсор.",
              sample: "autocomplete: shown len=14 ms=160 ctx=524 app=com.tinyspeck.slackmacgap …"),
        Entry(["autocomplete: accepted word"], .suggestShown, .normal, "Принято слово (Tab)", "Вы приняли одно слово подсказки.", sample: "autocomplete: accepted word len=5"),
        Entry(["autocomplete: accepted all"], .suggestShown, .normal, "Принята вся подсказка (→)", "Вы приняли подсказку целиком.", sample: "autocomplete: accepted all len=17"),
        Entry(["autocomplete: hidden reason=typed"], .suggestShown, .normal, "Подсказка спрятана: вы печатали дальше",
              "Набранная буква не совпала с подсказкой — она не подошла.", sample: "autocomplete: hidden reason=typed"),
        Entry(["autocomplete: hidden reason=consumed"], .suggestShown, .normal, "Подсказка напечатана вами",
              "Вы сами набрали то, что предлагалось, до конца.", sample: "autocomplete: hidden reason=consumed"),
        Entry(["autocomplete: hidden reason=stale"], .suggestShown, .note, "Подсказка устарела",
              "Поле изменилось с момента показа — подсказка убрана, чтобы не вставить её не туда.", sample: "autocomplete: hidden reason=stale"),
        Entry(["autocomplete: hidden reason="], .suggestShown, .normal, "Подсказка спрятана",
              "esc — вы нажали Esc; key — нажата клавиша управления (стрелки, ⌘…); click — щелчок мышью; app — переключились в другую программу.",
              sample: "autocomplete: hidden reason=key code=123 mods=0"),
        Entry(["autocomplete: panel not visible after show"], .suggestShown, .note, "Подсказке не хватило места",
              "Курсор стоит у правого края поля — подсказка не поместилась и не показана.", sample: "autocomplete: panel not visible after show (no room or empty)"),

        // MARK: Подсказки: молчание
        Entry(["autocomplete: empty suggestion"], .suggestSilent, .note, "Модель не уверена — подсказки нет",
              "p1 — уверенность модели в первом слове, need — порог. p1 ниже need → подсказка не показана. raw=0 — модель вообще ничего не предложила. patient=N больше нуля — менее уверенный вариант появится после паузы. midword=true — курсор стоял внутри слова.",
              action: "Хотите чаще — «Частота подсказок → Чаще» или свои пороги в «Тонкой настройке».",
              sample: "autocomplete: empty suggestion ms=437 raw=25 kept=0 p1=0.16 need=0.3 midword=false patient=24"),
        Entry(["autocomplete: no request", "too little text"], .suggestSilent, .normal, "Мало текста",
              "В поле меньше нужного числа букв или курсор в начале строки — модель не спрашивали.",
              action: "Число букв меняется в «Тонкой настройке → Начинать после».", sample: "autocomplete: no request — too little text or line start"),
        Entry(["autocomplete: no request", "text after the caret"], .suggestSilent, .normal, "Курсор не в конце строки",
              "Справа от курсора есть текст — в середине строки Tolk не подсказывает.", sample: "autocomplete: no request — text after the caret (12 chars) app=…"),
        Entry(["autocomplete: no request", "field not read"], .suggestSilent, .note, "Программа не отдала текст поля",
              "Tolk не смог прочитать, что вы печатаете. Причина — в строке «read refused» рядом.",
              sample: "autocomplete: no request — field not read"),
        Entry(["autocomplete: no request", "model not ready"], .suggestSilent, .note, "Модель ещё не готова",
              "Модель подсказок загружается (несколько секунд после запуска или смены модели) или не запущена.",
              action: "Если так постоянно — «Настройки → Модели»: модель должна быть скачана и выбрана.", sample: "autocomplete: no request — model not ready (starting)"),
        Entry(["autocomplete: no request", "paused by Esc"], .suggestSilent, .normal, "Пауза после Esc",
              "Вы спрятали подсказку клавишей Esc — до Tab, Enter или перехода в другое поле Tolk молчит.", sample: "autocomplete: no request — paused by Esc"),
        Entry(["autocomplete: no request", "Перевод при наборе"], .suggestSilent, .normal, "Работает «Перевод при наборе»",
              "В этой программе включён перевод при наборе — подсказки уступают ему место.", sample: "autocomplete: no request — «Перевод при наборе» owns this app"),
        Entry(["autocomplete: no request", "secure input"], .suggestSilent, .normal, "Поле для пароля",
              "Пока вводится пароль, Tolk ничего не читает и не подсказывает.", sample: "autocomplete: no request — secure input"),
        Entry(["autocomplete: no request", "while the model answered"], .suggestSilent, .normal, "Вы печатали быстрее модели",
              "Пока модель думала, текст или фокус изменились — ответ уже не к месту и выброшен.", sample: "autocomplete: no request — field changed while the model answered (ms=310, before 41 → 44 chars)"),
        Entry(["autocomplete: no request"], .suggestSilent, .normal, "Запрос к модели не отправлялся", "После тире — причина.", sample: "autocomplete: no request — …"),
        Entry(["autocomplete: small/search field skipped"], .suggestSilent, .normal, "Поле не для подсказок",
              "Строка поиска, адресная строка, ячейка таблицы, поле почты или слишком маленькое поле — здесь подсказки не нужны.",
              sample: "autocomplete: small/search field skipped (search-field) app=com.apple.Safari role=AXTextField sub=AXSearchField"),
        Entry(["autocomplete: request failed"], .suggestSilent, .problem, "Модель подсказок не ответила",
              "Запрос к llama-server завершился ошибкой (код после слова failed).",
              action: "Разовая ошибка — не страшно. Если подряд — «Настройки → Автодополнение → Повторить» или перезапустите Tolk.",
              sample: "autocomplete: request failed http=503"),
        Entry(["autocomplete: context screen unchanged"], .suggestSilent, .normal, "Экран не менялся",
              "Текст окна уже распознан — повторно снимок не делался.", sample: "autocomplete: context screen unchanged, OCR skipped ms=2"),
        Entry(["autocomplete: context source="], .suggestSilent, .normal, "Откуда взят контекст разговора",
              "ax — программа отдала текст окна сама; ocr — распознан со снимка окна; none — контекста нет. chars — сколько знаков.",
              sample: "autocomplete: context source=ocr chars=511 ms=501"),
        Entry(["autocomplete: word bias"], .suggestSilent, .normal, "Обновлён список ваших слов",
              "Слова, которые вы часто пишете, переданы модели («Выбор слов»).", sample: "autocomplete: word bias medium words=300 tokens=247"),

        // MARK: Вставка
        Entry(["autocomplete: not inserted, field check failed"], .suggestInsert, .problem, "Tab нажат, но подсказка не вставлена",
              "Перед вставкой поле перечитано и оказалось другим. В скобках причина: text — текст перед курсором изменился; element — фокус в другом поле; pid / bundle — другая программа; no-read — программа не успела ответить за 25 мс. Tab в этом случае уходит в программу.",
              action: "Если повторяется в одной программе — пришлите эти строки: по ним видно, что именно меняется.",
              sample: "autocomplete: not inserted, field check failed (text)"),
        Entry(["autocomplete: inserting with text after the caret"], .suggestInsert, .note, "Вставлено, хотя после курсора есть текст",
              "Программа сообщила текст справа от курсора (tail — его длина и вид знаков: L — буква, 9 — цифра, U+… — код знака). Подсказка всё равно вставлена.",
              sample: "autocomplete: inserting with text after the caret tail=2:[U+002C U+0020] app=com.tinyspeck.slackmacgap"),
        Entry(["autocomplete: insert had no effect even via paste"], .suggestInsert, .problem, "Программа не приняла вставку",
              "Ни набор по буквам, ни вставка через буфер обмена не изменили поле.",
              action: "В этой программе подсказки не работают — добавьте её в «Где не подсказывать».", sample: "autocomplete: insert had no effect even via paste app=com.example.app"),
        Entry(["autocomplete: insert had no effect, switching to paste"], .suggestInsert, .note, "Вставка переключена на буфер обмена",
              "Программа не приняла набор по буквам — для неё Tolk теперь вставляет через буфер (и возвращает его содержимое).",
              sample: "autocomplete: insert had no effect, switching to paste app=com.example.app"),
        Entry(["autocomplete: reposition dropped"], .suggestInsert, .note, "Остаток подсказки убран",
              "После принятого слова поле изменилось не так, как ожидалось — оставшаяся часть подсказки спрятана.", sample: "autocomplete: reposition dropped (text)"),

        // MARK: Чтение поля
        Entry(["autocomplete: read refused", "step=text-selected"], .field, .normal, "В поле выделен текст",
              "Пока что-то выделено, подсказки не показываются.", sample: "autocomplete: read refused app=ru.keepcoder.Telegram step=text-selected role=AXTextArea …"),
        Entry(["autocomplete: read refused", "step=not-editable"], .field, .normal, "Фокус не в поле ввода",
              "Курсор стоит на странице или в элементе, куда нельзя печатать.", sample: "autocomplete: read refused app=com.google.Chrome step=not-editable role=AXWebArea …"),
        Entry(["autocomplete: read refused", "step=secure-field"], .field, .normal, "Поле пароля", "Такие поля Tolk не читает.", sample: "autocomplete: read refused app=… step=secure-field"),
        Entry(["autocomplete: read refused", "step=budget"], .field, .note, "Программа отвечает медленно",
              "Программа не успела отдать текст поля за отведённое время — подсказка пропущена.",
              action: "Если постоянно в одной программе — она, вероятно, занята или зависла.", sample: "autocomplete: read refused app=… step=budget"),
        Entry(["autocomplete: read refused"], .field, .note, "Программа не отдаёт текст поля",
              "step — на каком шаге чтение остановилось (no-focused-element — нет поля в фокусе; no-selection-attrs, markers:… — программа не сообщает положение курсора).",
              action: "Если программа важна — включите «Текст окна со снимка экрана»; если нет — добавьте её в «Где не подсказывать».",
              sample: "autocomplete: read refused app=com.example.app step=no-selection-attrs role=AXTextArea …"),

        // MARK: Опечатки и эмодзи
        Entry(["autocomplete: instant not applied"], .typing, .note, "Исправление не применено",
              "Между показом исправления и нажатием Tab поле изменилось — Tolk ничего не тронул.", sample: "autocomplete: instant not applied, field changed"),
        Entry(["autocomplete: accepted instant"], .typing, .normal, "Исправление или эмодзи принято", "replace — сколько знаков заменено.", sample: "autocomplete: accepted instant replace=9 len=9"),
        Entry(["autocomplete: instant replace="], .typing, .normal, "Показано исправление или эмодзи", "replace — сколько знаков будет заменено.", sample: "autocomplete: instant replace=9 app=com.tinyspeck.slackmacgap"),

        // MARK: Модель подсказок
        Entry(["autocomplete: модель остановилась"], .model, .problem, "Модель подсказок упала",
              "llama-server завершился сам. Tolk перезапустит его через 2, 10 и 60 секунд.",
              action: "Если падает снова — включите «Подробный журнал» и посмотрите файл llama-server.log в папке журнала; часто причина в нехватке памяти.",
              sample: "autocomplete: модель остановилась (код 9, см. llama-server.log)"),
        Entry(["autocomplete: automatic restarts exhausted"], .model, .problem, "Модель не поднялась после трёх попыток", "Автоперезапуски закончились.",
              action: "«Настройки → Автодополнение → Повторить».", sample: "autocomplete: automatic restarts exhausted — waiting for «Повторить»"),
        Entry(["autocomplete: restart in"], .model, .note, "Перезапуск модели запланирован", "Через сколько секунд и какая это попытка.", sample: "autocomplete: restart in 10 s (attempt 2)"),
        Entry(["autocomplete: нет llama-server"], .model, .problem, "Не установлен llama-server",
              "Программа, которая запускает модель подсказок, не найдена.", action: "В Терминале: brew install llama.cpp", sample: "autocomplete: нет llama-server (brew install llama.cpp)"),
        Entry(["autocomplete: нет файла модели"], .model, .problem, "Нет файла модели",
              "Выбранный файл модели подсказок не найден на диске.", action: "«Настройки → Модели»: скачайте модель или выберите другую.", sample: "autocomplete: нет файла модели: gemma-4-E2B-abl-Q4_K.gguf"),
        Entry(["autocomplete: порт"], .model, .problem, "Порт модели занят", "Порт 8178 использует другая программа.",
              action: "Закройте её или перезагрузите Mac.", sample: "autocomplete: порт 8178 занят другой программой"),
        Entry(["autocomplete: автодополнение уже запущено"], .model, .problem, "Запущен второй Tolk", "Модель держит другая копия Tolk.",
              action: "Закройте лишнюю копию.", sample: "autocomplete: автодополнение уже запущено в другом Tolk (pid 123)"),
        Entry(["autocomplete: модель не загрузилась"], .model, .problem, "Модель не загрузилась за 90 секунд", "Tolk попробует ещё раз.",
              action: "Если повторяется — выберите модель поменьше.", sample: "autocomplete: модель не загрузилась за 90 с"),
        Entry(["autocomplete: не запустился llama-server"], .model, .problem, "llama-server не запустился", "После двоеточия — системная причина.",
              action: "Переустановите: brew reinstall llama.cpp", sample: "autocomplete: не запустился llama-server: …"),
        Entry(["autocomplete: stopping a llama-server left"], .model, .normal, "Убрана модель от прошлого запуска",
              "От предыдущего Tolk остался работающий llama-server — он остановлен.", sample: "autocomplete: stopping a llama-server left by a previous Tolk (pid 412)"),
        Entry(["autocomplete: starting llama-server"], .model, .normal, "Модель подсказок запускается", "Имя файла модели.", sample: "autocomplete: starting llama-server with gemma-4-E2B-abl-Q4_K.gguf"),
        Entry(["autocomplete: model ready"], .model, .normal, "Модель подсказок готова", "За сколько секунд загрузилась.", sample: "autocomplete: model ready in 2.2 s"),
        Entry(["autocomplete: event tap not created"], .model, .problem, "Нет доступа к клавиатуре",
              "macOS не дала Tolk следить за нажатиями — без этого нет ни подсказок, ни Tab.",
              action: "«Настройки → Общие → Разрешения macOS → Универсальный доступ».", sample: "autocomplete: event tap not created (Accessibility/Input Monitoring missing?) trusted=false"),
        Entry(["autocomplete: started"], .model, .normal, "Автодополнение включено", "Tolk начал следить за набором.", sample: "autocomplete: started"),
        Entry(["autocomplete: stopped"], .model, .normal, "Автодополнение выключено", "Tolk перестал следить за набором.", sample: "autocomplete: stopped"),
        Entry(["models: download failed"], .model, .problem, "Модель не скачалась", "После двоеточия — причина по-русски.",
              action: "«Настройки → Модели → Продолжить / Повторить».", sample: "models: download failed qwen3.5-4B-abl-Q4_K_M.gguf: Скачивание прервалось: …"),
        Entry(["models:"], .model, .normal, "Файлы моделей", "Скачивание начато, завершено, отменено; файл добавлен или перемещён в Корзину.", sample: "models: downloaded gemma-4-E4B-abl-Q4_K.gguf (5,3 ГБ)"),

        // MARK: Сервер
        Entry(["server ", "unavailable"], .server, .problem, "Сервер перевода недоступен",
              "Домашний сервер перестал отвечать. Пока он недоступен, работает запасной перевод (если включён).",
              action: "Проверьте, что сервер включён и в той же сети; «Настройки → Перевод → Проверить».", sample: "server Gemma: unavailable"),
        Entry(["server ", "available"], .server, .normal, "Сервер перевода на связи", "Сервер ответил.", sample: "server Gemma: available"),
        Entry(["server models:", "Не удалось"], .server, .problem, "Действие с моделью на сервере не удалось", "Текст после двоеточия объясняет, что именно.",
              sample: "server models: Не удалось скачать «gemma4:26b»: …"),
        Entry(["server models:"], .server, .normal, "Модели на сервере", "Скачивание, подготовка для перевода или удаление модели на сервере.", sample: "server models: Модель перевода «gemma4-26b-translate» готова — её можно выбрать."),

        // MARK: Снимок экрана
        Entry(["capture: ocr FAILED"], .capture, .problem, "Текст на снимке не распознан", "Системное распознавание текста вернуло ошибку.",
              action: "Попробуйте выделить область ещё раз.", sample: "capture: ocr FAILED …"),
        Entry(["capture: snapshot failed"], .capture, .problem, "Снимок экрана не получен", "macOS не отдала изображение экрана.",
              action: "«Настройки → Общие → Разрешения macOS → Запись экрана».", sample: "capture: snapshot failed …"),
        Entry(["capture: no text found"], .capture, .note, "В выделенной области нет текста", "Распознавать нечего.", sample: "capture: no text found"),
        Entry(["capture: selection cancelled"], .capture, .normal, "Выделение отменено", "Вы нажали Esc или щёлкнули без выделения.", sample: "capture: selection cancelled reason=esc"),
        Entry(["capture"], .capture, .normal, "Снимок области экрана", "Шаги: нажата ⌥⇧S, показана рамка, выделена область, сделан снимок, распознан текст, открыт перевод.",
              sample: "capture: ocr chars=212 ms=180"),
        Entry(["image page:"], .capture, .normal, "Страница «Фото и скриншоты»", "Распознавание картинки на странице.", sample: "image page: ocr page=1 chars=540"),

        // MARK: Перевод при наборе
        Entry(["type-translate: hotkey taken"], .typeTranslate, .problem, "Сочетание клавиш занято",
              "Сочетание для «Перевода при наборе» уже использует другая программа.", action: "«Настройки → Общие → Горячие клавиши»: задайте другое.", sample: "type-translate: hotkey taken"),
        Entry(["type-translate: field not readable"], .typeTranslate, .note, "Поле не читается",
              "Режим не смог прочитать ваш текст: чаще всего в поле что-то выделено. Причина — в строке «read refused» выше.", sample: "type-translate: field not readable app=ru.keepcoder.Telegram …"),
        Entry(["type-translate: no translation"], .typeTranslate, .note, "Перевод не получен", "Сервер не ответил; запасной перевод в этом режиме не используется, чтобы переписка не уходила в интернет.",
              sample: "type-translate: no translation (URLError) len=42"),
        Entry(["type-translate: not replaced"], .typeTranslate, .note, "Текст не заменён", "Между показом перевода и Tab поле изменилось.", sample: "type-translate: not replaced, field check failed (text)"),
        Entry(["type-translate: select-all refused"], .typeTranslate, .note, "Программа не дала заменить текст", "Замена делается через «выделить всё» — программа это не поддержала.",
              sample: "type-translate: select-all refused app=…"),
        Entry(["type-translate:"], .typeTranslate, .normal, "Перевод при наборе", "Режим включён или выключен, перевод показан, спрятан или вставлен.", sample: "type-translate: shown ru->en in=42 out=45 ms=900"),

        // MARK: Память стиля
        Entry(["style:", "not readable"], .style, .problem, "Ключ памяти стиля не читается", "Примеры зашифрованы, а ключ недоступен — память стиля приостановлена, данные не тронуты.",
              action: "Если ключ утерян — «Настройки → Автодополнение → Ваш стиль → Удалить…» начнёт память заново.", sample: "style: keychain key not readable (access denied?) — kept, style memory paused"),
        Entry(["style:", "not a valid key"], .style, .problem, "Файл ключа памяти стиля повреждён", "Память стиля приостановлена, данные не тронуты.",
              action: "«Ваш стиль → Удалить…» начнёт память заново.", sample: "style: style.key exists but is not a valid key — kept, style memory paused"),
        Entry(["style: skipped sensitive-looking"], .style, .normal, "Сообщение не запомнено", "Текст похож на пароль или ключ — в память стиля он не попал.", sample: "style: skipped sensitive-looking text len=24"),
        Entry(["style:"], .style, .normal, "Память стиля", "Примеры загружены, сохранён новый, память сжата или очищена.", sample: "style: saved len=64 total=121"),

        // MARK: Программа
        Entry(["UNCAUGHT EXCEPTION"], .app, .problem, "Внутренняя ошибка программы", "Tolk поймал ошибку, которой не ожидал.",
              action: "«Журнал → Скопировать отчёт» и отправьте разработчику.", sample: "UNCAUGHT EXCEPTION NSRangeException: …"),
        Entry(["another Tolk is already running"], .app, .note, "Вторая копия Tolk закрылась", "Tolk уже запущен — новая копия передала ему управление и вышла.", sample: "another Tolk is already running (pid 812) — quitting"),
        Entry(["launch "], .app, .normal, "Запуск", "Версия, номер сборки и параметры запуска.", sample: "launch 0.8.6 (сборка 58, 779cb1c), args: --background"),
        Entry(["settings changed:"], .app, .normal, "Настройки изменены", "Активный профиль глоссария, модель перевода и запасной переводчик после сохранения.", sample: "settings changed: profile=work model=gemma-translate fallback=apple"),
        Entry(["power:"], .app, .normal, "Смена питания", "Mac перешёл на батарею (battery) или на сеть (AC) — действуют настройки «На батарее».", sample: "power: battery"),
        Entry(["log cleared"], .app, .normal, "Журнал очищен", "Вы очистили журнал в настройках.", sample: "log cleared by the user"),
        Entry(["created rules file"], .app, .normal, "Создан файл глоссария", "Для нового профиля создан пустой файл правил.", sample: "created rules file for profile p3"),
        Entry(["window not in front"], .app, .normal, "Окно Tolk поднято повторно", "Окно не вышло на передний план с первого раза.", sample: "window not in front after 0.3s — activating again"),
        Entry(["last window closed"], .app, .normal, "Окно закрыто", "Фокус возвращён программе, в которой вы работали.", sample: "last window closed — focus back to Slack"),
        Entry(["quit"], .app, .normal, "Выход", "Tolk закрыт обычным способом.", sample: "quit"),
    ]

    /// The event part of a log line: without "2026-11-11 12:14:01 " (or the older "2026-11-11T11:14:01Z ").
    public static func message(of line: String) -> Substring {
        guard let first = line.first, first.isNumber, let sp = line.firstIndex(of: " ") else { return Substring(line) }
        let rest = line[line.index(after: sp)...]
        if line[..<sp].contains("T") { return rest }
        guard let sp2 = rest.firstIndex(of: " ") else { return rest }
        return rest[rest.index(after: sp2)...]
    }

    private static func matches(_ e: Entry, _ msg: Substring) -> Bool {
        // The first key is how the event starts; the others may be anywhere in it.
        guard let head = e.match.first, msg.hasPrefix(head) else { return false }
        return e.match.dropFirst().allSatisfy { msg.contains($0) }
    }

    /// The guide entry for a log line (with or without its timestamp); nil for a line the guide does not know.
    public static func explain(_ line: String) -> Entry? {
        let msg = message(of: line)
        return entries.first { matches($0, msg) }
    }

    /// Is this line a problem? Unknown lines fall back to alarming words.
    public static func isProblem(_ line: String) -> Bool {
        if let e = explain(line) { return e.kind == .problem }
        let l = line.lowercased()
        return ["failed", "error", "crash", "exception", "не удалось"].contains { l.contains($0) }
    }

    public struct Count: Sendable { public let entry: Entry; public let count: Int }

    /// What happened in these lines, most frequent first; only problems and notes unless `all`.
    public static func summary(_ lines: [String], all: Bool = false) -> [Count] {
        var counts: [Int: Int] = [:]
        for l in lines {
            let msg = message(of: l)
            guard let i = entries.firstIndex(where: { matches($0, msg) }) else { continue }
            if all || entries[i].kind != .normal { counts[i, default: 0] += 1 }
        }
        return counts.map { Count(entry: entries[$0.key], count: $0.value) }
            .sorted { a, b in
                if (a.entry.kind == .problem) != (b.entry.kind == .problem) { return a.entry.kind == .problem }
                return a.count != b.count ? a.count > b.count : a.entry.title < b.entry.title
            }
    }

    /// The whole guide as Markdown (README next to the log files and docs/journal.md).
    public static func markdown() -> String {
        var out = ["# Журнал Tolk: что значат строки", "",
                   "Журнал лежит в `~/Library/Logs/Tolk/tolk.log` (прошлый — `tolk.old.log`). Его удобнее смотреть в самом Tolk: "
                   + "Настройки → Журнал. В журнале нет текста, который вы переводите или печатаете, — только длины, времена и названия программ.", "",
                   "Каждая строка начинается с даты и времени (местное время), дальше — событие. Ниже события собраны по группам. Пометки:", "",
                   "- **обычное** — рабочее событие, ничего делать не нужно;", "- **к сведению** — не ошибка, но объясняет, почему что-то не произошло;",
                   "- **проблема** — что-то пошло не так; рядом написано, что делать.", "",
                   "Другие файлы в папке: `llama-server.log` — журнал самой модели подсказок (нужен, только если она падает), "
                   + "`stderr.log` — сообщения системы, `crash-*.txt` — записи о сбоях программы.", ""]
        for g in Group.allCases {
            let items = entries.filter { $0.group == g }
            guard !items.isEmpty else { continue }
            out += ["## " + g.title, "", g.about, ""]
            for e in items {
                let mark = e.kind == .problem ? "проблема" : (e.kind == .note ? "к сведению" : "обычное")
                out.append("### \(e.title) — \(mark)")
                out.append("")
                out.append("`\(e.sample)`")
                out.append("")
                out.append(e.meaning)
                if let a = e.action { out += ["", "**Что делать:** " + a] }
                out.append("")
            }
        }
        return out.joined(separator: "\n")
    }
}

extension SelfTest {
    static func logGuide(_ check: Check) {
        typealias G = LogGuide
        // Every sample is explained by its own entry (an earlier, broader entry would shadow it).
        var shadowed: [String] = []
        for e in G.entries where G.explain(e.sample)?.title != e.title { shadowed.append(e.title + " ← " + (G.explain(e.sample)?.title ?? "nil")) }
        check(shadowed.isEmpty, "log guide: every sample matches its own entry", shadowed.joined(separator: "; "))
        check(G.Group.allCases.allSatisfy { g in G.entries.contains { $0.group == g } }, "log guide: no empty groups")
        check(G.entries.allSatisfy { $0.kind != .problem || $0.action != nil || $0.group == .server }, "log guide: problems say what to do")
        check(G.isProblem("2026-11-11 12:00:00 translate: popup FAILED in=10 after 300 ms: x") && !G.isProblem("2026-11-11 12:00:00 translate: popup en→ru in=10 out=12 provider=Gemma route=home ms=300"),
              "log guide: failed translation is a problem, a normal one is not")
        check(!G.isProblem("autocomplete: read refused app=ru.keepcoder.Telegram step=text-selected role=AXTextArea") && !G.isProblem("autocomplete: read refused app=x step=not-editable"),
              "log guide: selected text and no field are not problems")
        check(G.isProblem("autocomplete: not inserted, field check failed (text)") && G.explain("autocomplete: inserting with text after the caret tail=2:[U+002C U+0020] app=x")?.kind == .note,
              "log guide: not inserted is a problem, inserted with a tail is a note")
        check(G.message(of: "2026-11-11 12:00:01 quit") == "quit" && G.message(of: "2026-11-11T11:00:02Z quit") == "quit" && G.message(of: "quit") == "quit", "log guide: timestamp is stripped")
        check(G.explain("something nobody wrote") == nil && G.isProblem("weird thing failed") && !G.isProblem("weird thing"), "log guide: unknown lines fall back to keywords")
        let s = G.summary(["2026-11-11 12:00:01 autocomplete: empty suggestion ms=1", "2026-11-11T11:00:02Z autocomplete: empty suggestion ms=2", "server Gemma: unavailable", "autocomplete: shown len=3"])
        check(s.count == 2 && s[0].entry.kind == .problem && s[1].count == 2, "log guide: summary puts problems first and skips routine lines", "\(s.map { "\($0.entry.title):\($0.count)" })")
        let md = G.markdown()
        check(md.contains("## Перевод") && md.contains("**Что делать:**") && md.contains("### Подсказка показана — обычное"), "log guide: markdown has groups, actions and marks")
    }
}
