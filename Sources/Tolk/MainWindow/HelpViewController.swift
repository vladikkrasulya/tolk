// «Как пользоваться»: every feature with its shortcut and a tiny looping animation of what happens.
// Animations step on a slow timer and run only while the page is on screen (no CPU when hidden).
import AppKit
import SwiftUI

final class HelpViewController: NSViewController {
    init() { super.init(nibName: nil, bundle: nil); title = "Как пользоваться" }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = NSHostingView(rootView: HelpView()) }
}

// MARK: - Page

/// Steps one card's animation while the pointer is over it. Idle cards show the final state and cost
/// nothing (running all six loops at once on a 120 Hz screen took 16–24% CPU).
@MainActor
final class HelpClock: ObservableObject {
    static let restPhase = 4          // "result" frame shown when not hovered
    @Published var phase = HelpClock.restPhase
    private var timer: Timer?
    func start() {
        guard timer == nil else { return }
        phase = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.phase = (self.phase + 1) % 6 }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; phase = HelpClock.restPhase }
}

/// Fixed-size canvas; animates only while `active` (pointer over the card).
struct AnimCanvas<Content: View>: View {
    var active: Bool
    let content: (Int) -> Content
    @StateObject private var clock = HelpClock()
    var body: some View {
        content(clock.phase)
            .frame(width: 240, height: 110)
            .animation(.easeInOut(duration: 0.3), value: clock.phase)
            .onChange(of: active) { _, on in on ? clock.start() : clock.stop() }
            .onDisappear { clock.stop() }
    }
}

struct HelpView: View {
    private let cols = [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Всё самое нужное — на одной странице. Наведите курсор на карточку — анимация покажет, как это работает.")
                    .foregroundStyle(.secondary)
                Text("Клавиши: ⌘ — Command (на PC-клавиатуре Win), ⌥ — Option (Alt), ⌃ — Control (Ctrl), ⇧ — Shift.")
                    .font(.callout).foregroundStyle(.tertiary)
                LazyVGrid(columns: cols, spacing: 14) {
                    HelpCard(title: "Перевести выделенное", keys: ["⌘", "C", "⌘", "C"], keysNote: "дважды быстро",
                             text: "Выделите текст в любой программе и дважды нажмите ⌘C — рядом появится перевод.") { hovering in
                        AnimCanvas(active: hovering) { phase in DoubleCopyAnim(phase: phase) }
                    }
                    HelpCard(title: "Ответить партнёру", keys: ["R"], keysNote: "в окне перевода",
                             text: "Его сообщение остаётся сверху, вы пишете по-своему — ответ переводится на его язык. «Вставить в чат ⌘↩» — и отправляете сами.") { hovering in
                        AnimCanvas(active: hovering) { phase in ReplyAnim(phase: phase) }
                    }
                    HelpCard(title: "Перевести и заменить", keys: ["⌃", "⌥", "T"], keysNote: "по умолчанию",
                             text: "Выделите свой текст в Slack, Telegram или почте — он заменится переводом прямо там. Тон подберётся по программе.") { hovering in
                        AnimCanvas(active: hovering) { phase in ReplaceAnim(phase: phase, from: "Скинь стату за неделю", to: "Send me the weekly stats") }
                    }
                    HelpCard(title: "Причесать и заменить", keys: ["⌃", "⌥", "P"], keysNote: "по умолчанию",
                             text: "Без перевода: исправит грамматику и сделает текст как у носителя из индустрии, на том же языке.") { hovering in
                        AnimCanvas(active: hovering) { phase in ReplaceAnim(phase: phase, from: "we was checked yours traffic", to: "we've checked your traffic") }
                    }
                    HelpCard(title: "Исправить раскладку", keys: ["⌃", "⌥", "L"], keysNote: "по умолчанию",
                             text: "Набрали «Ghbdtn» вместо «Привет» (или наоборот)? Выделите текст — он заменится на правильный, без модели и мгновенно. Русская и украинская раскладки, смешанный текст — по словам.") { hovering in
                        AnimCanvas(active: hovering) { phase in ReplaceAnim(phase: phase, from: "Ghbdtn, rfr ltkf?", to: "Привет, как дела?") }
                    }
                    HelpCard(title: "Перевод при наборе", keys: ["⌃", "⌥", "R"], keysNote: "включить для программы, по умолчанию",
                             text: "Пишете в чате по-своему — под полем появляется перевод на язык собеседника. Tab вставляет его вместо вашего текста, Esc оставляет ваш. Ничего не отправляется.") { hovering in
                        AnimCanvas(active: hovering) { phase in ReplaceAnim(phase: phase, from: "Да, отключим сабы сегодня", to: "Yes, we'll disable the subs today") }
                    }
                    HelpCard(title: "Перевести с экрана", keys: ["⌥", "⇧", "S"], keysNote: "по умолчанию",
                             text: "Выделите мышью область экрана — текст распознается прямо на Mac и переведётся. Если вы в окне Tolk — результат появится в «Фото и скриншоты», иначе — рядом с областью.") { hovering in
                        AnimCanvas(active: hovering) { phase in CaptureAnim(phase: phase) }
                    }
                    HelpCard(title: "Фото и документы", keys: [], keysNote: "разделы «Фото и скриншоты» и «Документы»",
                             text: "Фото страницы или скриншот — в «Фото и скриншоты». Целый документ (Word, PDF, RTF, TXT) — в «Документы»: переведётся по абзацам и сохранится в Word с оригиналом или без.") { hovering in
                        AnimCanvas(active: hovering) { phase in DropAnim(phase: phase) }
                    }
                }
                PopupButtonsCard()
                BigWindowCard()
                TroubleCard()
                AutocompleteHelpCard()
            }
            .padding(24)
        }
    }
}

// MARK: - Building blocks

struct HelpCard<Anim: View>: View {
    let title: String
    let keys: [String]
    let keysNote: String?
    let text: String
    @ViewBuilder let anim: (Bool) -> Anim
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            anim(hovering)
                .frame(maxWidth: .infinity)
                .frame(height: 110)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Spacer()
                ForEach(Array(keys.enumerated()), id: \.offset) { _, k in KeyCap(k) }
            }
            if let keysNote { Text(keysNote).font(.caption).foregroundStyle(.secondary) }
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: TolkStyle.cardRadius).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: TolkStyle.cardRadius).stroke(hovering ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08)))
        .onHover { hovering = $0 }
    }
}

struct KeyCap: View {
    let label: String
    var pressed = false
    init(_ label: String, pressed: Bool = false) { self.label = label; self.pressed = pressed }
    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(pressed ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
            .offset(y: pressed ? 1.5 : 0)
    }
}

/// Grey "text lines" placeholder.
struct Lines: View {
    var count = 3
    var width: CGFloat = 120
    var color = Color.primary.opacity(0.18)
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(color).frame(width: i == count - 1 ? width * 0.6 : width, height: 6)
            }
        }
    }
}

/// Small rounded "window".
struct MiniWindow<Content: View>: View {
    var tint: Color = Color(nsColor: .windowBackgroundColor)
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
    }
}

// MARK: - Animations (phase 0…5 loops)

struct DoubleCopyAnim: View {
    let phase: Int
    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Lines(count: 3, width: 90, color: phase >= 1 ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.18))
                HStack(spacing: 4) { KeyCap("⌘", pressed: phase == 2 || phase == 3); KeyCap("C", pressed: phase == 2 || phase == 3) }
            }
            MiniWindow {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) { Text("EN → RU").font(.system(size: 9, weight: .semibold)); Spacer() }
                    Lines(count: 3, width: 80, color: Color.primary.opacity(0.35))
                }
                .frame(width: 96)
            }
            .opacity(phase >= 4 ? 1 : 0)
            .scaleEffect(phase >= 4 ? 1 : 0.9, anchor: .topLeading)
        }
    }
}

struct ReplyAnim: View {
    let phase: Int
    var body: some View {
        MiniWindow {
            VStack(alignment: .leading, spacing: 6) {
                Lines(count: 2, width: 150, color: Color.primary.opacity(0.22))
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
                HStack(spacing: 0) {
                    Text(String("Да, отключим сабы сегодня".prefix(min(25, phase * 7))))
                        .font(.system(size: 9))
                    Rectangle().fill(Color.accentColor).frame(width: 1, height: 10).opacity(phase < 4 ? 1 : 0)
                    Spacer(minLength: 0)
                }
                .frame(width: 160, height: 16)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15)))
                Text("→ Yes, we'll disable the subs today").font(.system(size: 9)).foregroundStyle(.secondary)
                    .opacity(phase >= 4 ? 1 : 0)
            }
        }
    }
}

struct ReplaceAnim: View {
    let phase: Int
    let from: String
    let to: String
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(phase >= 3 ? to : from)
                    .font(.system(size: 11))
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 3).fill(phase >= 1 && phase < 3 ? Color.accentColor.opacity(0.3) : .clear))
                    .contentTransition(.opacity)
                Spacer()
            }
            .padding(8)
            .frame(width: 210)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.18)))
            Text(phase == 2 ? "Перевожу…" : (phase >= 3 ? "Готово ✓" : " "))
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

struct CaptureAnim: View {
    let phase: Int
    var body: some View {
        ZStack(alignment: .topLeading) {
            Lines(count: 4, width: 150)
                .padding(.top, 14).padding(.leading, 20)
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .foregroundStyle(Color.accentColor)
                .background(Color.accentColor.opacity(0.08))
                .frame(width: phase >= 1 ? 160 : 10, height: phase >= 1 ? 50 : 8)
                .padding(.top, 8).padding(.leading, 14)
                .opacity(phase >= 1 && phase < 5 ? 1 : 0)
            MiniWindow {
                Lines(count: 2, width: 70, color: Color.primary.opacity(0.35)).frame(width: 80)
            }
            .padding(.top, 58).padding(.leading, 110)
            .opacity(phase >= 3 ? 1 : 0)
        }
        .frame(width: 220, height: 100, alignment: .topLeading)
    }
}

struct DropAnim: View {
    let phase: Int
    var body: some View {
        HStack(spacing: 22) {
            Image(systemName: "photo")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
                .offset(x: phase >= 1 && phase <= 2 ? 46 : 0)
                .opacity(phase >= 3 ? 0.3 : 1)
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(Color.primary.opacity(0.3))
                .frame(width: 120, height: 76)
                .overlay {
                    if phase >= 3 {
                        VStack(alignment: .leading, spacing: 6) {
                            Lines(count: 2, width: 90, color: Color.primary.opacity(0.22))
                            Lines(count: 2, width: 90, color: Color.accentColor.opacity(0.45))
                        }
                    }
                }
        }
    }
}

// MARK: - Popup buttons and trouble

private extension View {
    /// Full-width rounded card used by the info blocks under the feature grid.
    func infoCardStyle() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: TolkStyle.cardRadius).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: TolkStyle.cardRadius).stroke(Color.primary.opacity(0.08)))
    }
}

struct PopupButtonsCard: View {
    private let rows: [(String, String, String)] = [
        ("arrow.uturn.backward", "Обратный перевод", "проверить, что смысл не потерялся"),
        ("lightbulb", "Сноски", "пояснения к спорным терминам, «Так и оставить» / вариант — в глоссарий"),
        ("book", "В глоссарий", "закрепить, как переводить термин"),
        ("doc.on.doc", "Копировать", "⌘C"),
        ("text.insert", "Вставить", "⌘↩ — заменить выделенный текст переводом"),
        ("arrowshape.turn.up.left", "Ответить", "R — окно ответа партнёру, внутри готовые ответы ⌘1…⌘5"),
        ("list.bullet.rectangle", "Варианты перевода", "2–3 версии всего текста с пояснением, чем они отличаются"),
        ("arrow.up.left.and.arrow.down.right", "Открыть в окне перевода", "тот же текст в большом окне"),
        ("cursorarrow.click.2", "Выделить слово в переводе", "покажет варианты замены"),
        ("escape", "Закрыть", "Esc или клик мимо"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("В окне перевода").font(.headline)
            ForEach(rows, id: \.1) { icon, title, note in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: icon).frame(width: 20).foregroundStyle(Color.accentColor)
                    Text(title).frame(width: 190, alignment: .leading)
                    Text(note).foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.callout)
            }
            Text("Тон: «Авто» подбирается по программе (Slack и Telegram — чат, почта — письмо), «Чат» и «Письмо» — вручную.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Строка под переводом: ● зелёная — перевела модель дома, синяя — вне дома, оранжевая — запасной Google/Apple (без глоссария). Там же время до первого слова и скорость. «из кеша» — перевод взят из памяти; щёлкните «↻ заново», чтобы перевести без кеша.")
                .font(.caption).foregroundStyle(.secondary)
            Text("История — все переводы на этом Mac с поиском. Профиль «Работа / Дом» — меню Tolk или «Настройки»: у каждого свой глоссарий и модель.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .infoCardStyle()
    }
}

struct BigWindowCard: View {
    private let rows: [(String, String, String)] = [
        ("character.bubble", "Перевод", "живой перевод при наборе; ⌘↩ или ⌘R — заново. Кнопки «Короче», «Мягче», «Твёрже», «Проще», «По-деловому», «Прямо» и «ты» / «Вы» переписывают перевод, «Вернуть» откатывает"),
        ("arrowshape.turn.up.left", "Ответ", "вставьте сообщение собеседника — ваш ответ переведётся на его язык; «Что он имел в виду» разберёт смысл и тон"),
        ("square.and.pencil", "Составить", "тезисы своими словами → готовое сообщение на языке получателя в тоне «Нейтрально», «По-деловому», «Прямо» или «Дружелюбно», ⌘↩"),
        ("sidebar.right", "Подсказки", "проверка, сноски, обратный перевод, варианты слова и всего перевода, правка редактора. Щёлкните по предложению в переводе — варианты предложения"),
        ("clock.arrow.circlepath", "Последние", "недавние переводы из истории; файл, брошенный на страницу, откроется в «Документах»"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Большое окно (Tolk в меню, ⌘1…⌘7 — разделы)").font(.headline)
            ForEach(rows, id: \.1) { icon, title, note in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: icon).frame(width: 20).foregroundStyle(Color.accentColor)
                    Text(title).frame(width: 110, alignment: .leading)
                    Text(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .font(.callout)
            }
        }
        .infoCardStyle()
    }
}

struct AutocompleteHelpCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "text.cursor").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Автодополнение (по умолчанию выключено)").font(.headline)
                Text("Включается в меню Tolk → «Автодополнение» или в «Настройках». Пока вы печатаете, серый текст у курсора предлагает продолжение: Tab принимает слово, → — всё целиком, ⌥Tab — обычный Tab, Esc скрывает подсказку в этом поле. Модель работает на этом Mac. Опечатки и эмодзи (:fire) подсказываются и без модели. В терминалах, редакторах кода и полях паролей выключено — список в «Настройках». Сколько подсказок показано и принято — «Настройки» → «Автодополнение» → «Статистика» и меню.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .infoCardStyle()
    }
}

struct TroubleCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lifepreserver").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Если что-то не так").font(.headline)
                Text("Меню Tolk в строке меню → «Сообщить о проблеме…» копирует отчёт — просто перешлите его. Если Tolk упадёт, при следующем запуске он сам предложит скопировать отчёт. Иконка в строке меню показывает, кто переводит: модель на домашнем сервере или запасной перевод (Apple/Google, как выбрано в Настройках).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .infoCardStyle()
    }
}
