import BudouX
import SwiftUI

/// 日本語を文節の切れ目だけで折り返す (「はじめる」と同じ方式)。
/// 日本語には単語の間の空白がないので、そのままでは「ペアリン／グ」のように語の途中で折り返されることがある。
/// 改行の位置は `\n` で決め打ちせず (画面の幅が変わると半端な行ができる)、BudouX で文節に分けて幅に任せる。
enum Phrases {
    private static let parser = Parser()

    /// 文節の中では折り返さない文字列にする (文節の中の文字を Word Joiner でつなぎ、文節の間にゼロ幅スペースを入れる)。
    /// 段落の区切りの `\n` はそのまま残す
    static func wrapped(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.isEmpty ? $0 : parser.translate(sentence: $0) }
            .joined(separator: "\n")
    }
}

/// 文節の切れ目だけで折り返す `Text`。文や説明はこれで出す
func PhraseText(_ text: String) -> Text {
    Text(verbatim: Phrases.wrapped(text))
}
