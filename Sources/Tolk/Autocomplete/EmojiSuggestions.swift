// Instant emoji suggestions: ":fire" → "🔥". No model involved.
import Foundation

@MainActor
final class EmojiSuggestions: InstantSuggestionProvider {
    func suggestion(for field: FocusedField) -> InstantSuggestion? {
        guard let (code, len) = Self.trailingCode(in: field.textBefore) else { return nil }
        guard let e = Self.lookup(code) else { return nil }
        return InstantSuggestion(replaceCount: len, text: e, display: "\(e) :\(code):", blocksModel: true)
    }

    /// ":code" at the end of `text`: 2+ letters (or "+1"/"-1"), colon preceded by a space/line start.
    nonisolated static func trailingCode(in text: String) -> (String, Int)? {
        var chars: [Character] = []
        for ch in text.reversed() {
            if ch == ":" {
                guard chars.count >= 2 else { return nil }
                let before = text.dropLast(chars.count + 1).last
                guard before == nil || before == " " || before == "\n" || before == "\t" else { return nil }
                let code = String(chars.reversed())
                return (code.lowercased(), chars.count + 1)
            }
            guard ch.isLetter || ch.isNumber || ch == "_" || ch == "+" || ch == "-" else { return nil }
            chars.append(ch)
            if chars.count > 24 { return nil }
        }
        return nil
    }

    /// Exact code, otherwise the shortest code with this prefix (3+ chars typed).
    nonisolated static func lookup(_ code: String) -> String? {
        if let e = table[code] ?? ru[code] { return e }
        guard code.count >= 3 else { return nil }
        let all = Array(table.keys) + Array(ru.keys)
        let m = all.filter { $0.hasPrefix(code) }.sorted { ($0.count, $0) < ($1.count, $1) }
        return m.first.flatMap { table[$0] ?? ru[$0] }
    }

    nonisolated static let table: [String: String] = [
        "smile": "😄", "grin": "😁", "joy": "😂", "lol": "😂", "rofl": "🤣", "wink": "😉", "blush": "😊",
        "heart_eyes": "😍", "kiss": "😘", "cool": "😎", "sunglasses": "😎", "thinking": "🤔", "think": "🤔",
        "neutral": "😐", "unamused": "😒", "sweat": "😅", "sweat_smile": "😅", "cry": "😢", "sob": "😭",
        "angry": "😠", "rage": "🤬", "scream": "😱", "fearful": "😨", "sleepy": "😴", "zzz": "💤",
        "sick": "🤒", "nerd": "🤓", "hug": "🤗", "shrug": "🤷", "facepalm": "🤦", "pray": "🙏",
        "thanks": "🙏", "please": "🙏", "wave": "👋", "hi": "👋", "hello": "👋", "bye": "👋",
        "ok": "👌", "okay": "👌", "ok_hand": "👌", "+1": "👍", "-1": "👎", "thumbsup": "👍", "thumbsdown": "👎",
        "like": "👍", "dislike": "👎", "clap": "👏", "muscle": "💪", "strong": "💪", "fist": "✊",
        "point_up": "☝️", "point_right": "👉", "point_left": "👈", "point_down": "👇", "raised_hands": "🙌",
        "handshake": "🤝", "deal": "🤝", "v": "✌️", "peace": "✌️", "crossed_fingers": "🤞", "eyes": "👀",
        "brain": "🧠", "fire": "🔥", "hot": "🔥", "100": "💯", "boom": "💥", "sparkles": "✨", "star": "⭐",
        "star2": "🌟", "zap": "⚡", "rocket": "🚀", "tada": "🎉", "party": "🎉", "confetti": "🎊",
        "gift": "🎁", "trophy": "🏆", "medal": "🏅", "crown": "👑", "gem": "💎", "money": "💰",
        "moneybag": "💰", "dollar": "💵", "cash": "💵", "euro": "💶", "chart": "📈", "chart_up": "📈",
        "chart_down": "📉", "bar_chart": "📊", "target": "🎯", "dart": "🎯", "bulb": "💡", "idea": "💡",
        "heart": "❤️", "love": "❤️", "broken_heart": "💔", "blue_heart": "💙", "green_heart": "💚",
        "yellow_heart": "💛", "purple_heart": "💜", "black_heart": "🖤", "white_check_mark": "✅",
        "check": "✅", "done": "✅", "heavy_check_mark": "✔️", "x": "❌", "cross": "❌", "no": "🚫",
        "warning": "⚠️", "warn": "⚠️", "stop": "🛑", "question": "❓", "exclamation": "❗", "bangbang": "‼️",
        "info": "ℹ️", "bell": "🔔", "mute": "🔇", "lock": "🔒", "unlock": "🔓", "key": "🔑",
        "mag": "🔍", "search": "🔍", "link": "🔗", "pin": "📌", "pushpin": "📌", "paperclip": "📎",
        "memo": "📝", "note": "📝", "pencil": "✏️", "book": "📖", "books": "📚", "clipboard": "📋",
        "calendar": "📅", "date": "📅", "clock": "🕐", "hourglass": "⌛", "alarm": "⏰", "email": "📧",
        "mail": "📧", "envelope": "✉️", "phone": "📱", "iphone": "📱", "telephone": "☎️", "computer": "💻",
        "laptop": "💻", "keyboard": "⌨️", "bug": "🐛", "gear": "⚙️", "wrench": "🔧", "hammer": "🔨",
        "tools": "🛠️", "package": "📦", "truck": "🚚", "plane": "✈️", "car": "🚗", "house": "🏠",
        "coffee": "☕", "tea": "🍵", "beer": "🍺", "beers": "🍻", "wine": "🍷", "pizza": "🍕",
        "burger": "🍔", "cake": "🎂", "apple": "🍎", "sun": "☀️", "moon": "🌙", "cloud": "☁️",
        "rain": "🌧️", "snow": "❄️", "rainbow": "🌈", "earth": "🌍", "globe": "🌐", "tree": "🌳",
        "flower": "🌸", "rose": "🌹", "cat": "🐱", "dog": "🐶", "unicorn": "🦄", "monkey": "🙈",
        "poop": "💩", "skull": "💀", "ghost": "👻", "robot": "🤖", "alien": "👽", "music": "🎵",
        "headphones": "🎧", "movie": "🎬", "camera": "📷", "video": "📹", "microphone": "🎤",
        "arrow_right": "➡️", "arrow_left": "⬅️", "arrow_up": "⬆️", "arrow_down": "⬇️", "recycle": "♻️",
        "new": "🆕", "free": "🆓", "sos": "🆘", "top": "🔝", "soon": "🔜", "flag": "🏁", "red_flag": "🚩",
        "smirk": "😏", "relieved": "😌", "pensive": "😔", "confused": "😕", "slight_smile": "🙂",
        "upside_down": "🙃", "zany": "🤪", "salute": "🫡", "melting": "🫠", "pleading": "🥺",
    ]

    /// Russian synonyms for the most common ones.
    nonisolated static let ru: [String: String] = [
        "огонь": "🔥", "спасибо": "🙏", "спс": "🙏", "пожалуйста": "🙏", "привет": "👋", "пока": "👋",
        "ок": "👌", "окей": "👌", "супер": "👍", "класс": "👍", "лайк": "👍", "плохо": "👎",
        "смех": "😂", "ржу": "😂", "улыбка": "😄", "грусть": "😢", "плач": "😭", "злость": "😠",
        "сердце": "❤️", "любовь": "❤️", "думаю": "🤔", "подумать": "🤔", "глаза": "👀", "ракета": "🚀",
        "праздник": "🎉", "ура": "🎉", "деньги": "💰", "цель": "🎯", "идея": "💡", "готово": "✅",
        "галочка": "✅", "крестик": "❌", "внимание": "⚠️", "вопрос": "❓", "звезда": "⭐",
        "сила": "💪", "аплодисменты": "👏", "рукопожатие": "🤝", "кофе": "☕", "баг": "🐛",
        "рост": "📈", "падение": "📉", "почта": "📧", "звонок": "📞", "время": "⏰", "бомба": "💣",
    ]
}
