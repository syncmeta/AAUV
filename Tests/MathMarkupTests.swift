import Foundation

@main
struct MathMarkupTests {
    static func main() throws {
        let original = #"""
        价格 $5 和 $10。公式 \(x^2\) 与 $y+1$。

        \[\frac{a}{b}\]

        `echo $HOME`

           ~~~sh
           echo "$x+y$"
           ~~~
        """#
        let rendered = MathMarkup.rewrite(original)
        precondition(rendered.contains("价格 $5 和 $10。"))
        precondition(rendered.contains("`echo $HOME`") && rendered.contains("echo \"$x+y$\""))
        let links = rendered.split(separator: "(").compactMap { part -> URL? in
            guard part.hasPrefix("aauv-math://"), let end = part.firstIndex(of: ")") else { return nil }
            return URL(string: String(part[..<end]))
        }
        let formulae = links.compactMap(MathMarkup.parse)
        precondition(formulae.map(\.latex) == ["x^2", "y+1", #"\frac{a}{b}"#])
        precondition(formulae.map(\.display) == [false, false, true])
        let fenced = "~~~swift\r\nprint(\"$x+1$\")\r\n~~~\r\n"
        precondition(MathMarkup.rewrite(fenced) == fenced)
        let unfinished = "```bash\necho $x+y$"
        precondition(MathMarkup.rewrite(unfinished) == unfinished)
        let link = "[打开](https://example.invalid/path/(v)/$x+y$)"
        precondition(MathMarkup.rewrite(link) == link)
        let tooDeep = #"\("# + String(repeating: "{", count: 25) + "x" + String(repeating: "}", count: 25) + #"\)"#
        precondition(MathMarkup.rewrite(tooDeep) == tooDeep)
        let tooLong = #"\("# + String(repeating: "x", count: 1_025) + #"\)"#
        precondition(MathMarkup.rewrite(tooLong) == tooLong)
        let oversizedURL = URL(string: "aauv-math://i/" + String(repeating: "a", count: 1_500))!
        precondition(MathMarkup.parse(oversizedURL) == nil)
        print("Inline and display math, currency, protected code fences and rendering limits passed.")
    }
}
