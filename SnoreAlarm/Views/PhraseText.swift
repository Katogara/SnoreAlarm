import BudouX
import SwiftUI

/// 日本語を文節の切れ目だけで折り返す (「はじめる」と同じ方式)。
/// 日本語には単語の間の空白がないので、そのままでは「ペアリン／グ」のように語の途中で折り返されることがある。
/// 改行の位置は `\n` で決め打ちせず (画面の幅が変わると半端な行ができる)、BudouX で文節に分けて幅に任せる。
/// 英語など空白で単語を区切る言語では、そのまま出す
enum Phrases {
    private static let parser = Parser()

    /// 画面の言語が日本語か
    static let isJapanese = Bundle.main.preferredLocalizations.first?.hasPrefix("ja") ?? false

    /// 文節の中では折り返さない文字列にする (文節の中の文字を Word Joiner でつなぎ、文節の間にゼロ幅スペースを入れる)。
    /// 段落の区切りの `\n` はそのまま残す
    static func wrapped(_ text: String) -> String {
        guard isJapanese else { return text }
        return text.components(separatedBy: "\n")
            .map { $0.isEmpty ? $0 : parser.translate(sentence: $0) }
            .joined(separator: "\n")
    }

    /// 文と文のあいだに空白を入れない言語 (日本語・中国語)
    static let joinsWithoutSpace: Bool = {
        let lang = Bundle.main.preferredLocalizations.first ?? ""
        return lang.hasPrefix("ja") || lang.hasPrefix("zh")
    }()

    /// 訳した文をつなぐ。日本語と中国語はそのまま、英語や韓国語などは空白をはさむ
    static func joinSentences(_ sentences: [String]) -> String {
        sentences.joined(separator: joinsWithoutSpace ? "" : " ")
    }
}

/// 文節の切れ目だけで折り返す `Text`。文や説明はこれで出す。画面の言語に訳してから出す
func PhraseText(_ text: LocalizedStringResource) -> Text {
    Text(verbatim: Phrases.wrapped(String(localized: text)))
}

/// 訳し終えた文 (ログやエラーの文など) を、文節の切れ目だけで折り返して出す
func PhraseText(verbatim text: String) -> Text {
    Text(verbatim: Phrases.wrapped(text))
}
