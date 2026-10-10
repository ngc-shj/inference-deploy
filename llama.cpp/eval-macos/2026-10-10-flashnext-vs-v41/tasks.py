"""Task set for the Flash-Next vs DeepSeek V4.1 Flash comparison.

Each task: id, group, prompt, and a checker. Checkers return (score, max).
Coding tasks are scored by running hidden tests on the extracted code.
"""
import re

ANS = "\n\n最後の行に「答え: <答え>」の形で答えだけを書いてください。"


def last_answer(text):
    m = re.findall(r"答え\s*[:：]\s*(.+)", text)
    return m[-1].strip() if m else ""


def has_any(text, keys):
    return any(k in text for k in keys)


def keigo(src, accept, reject=()):
    prompt = f"次の文を、適切な敬語に直してください。直した文だけを1行で答えてください。\n\n{src}"

    def check(out):
        line = out.strip().splitlines()[0] if out.strip() else ""
        ok = has_any(line, accept) and not has_any(line, reject)
        return (1 if ok else 0, 1)
    return prompt, check


def answer_is(keys, reject=()):
    def check(out):
        a = last_answer(out).replace(" ", "").replace(",", "")
        return (1 if has_any(a, keys) and not has_any(a, reject) else 0, 1)
    return check


TASKS = []


def add(tid, group, prompt, check, think=False):
    TASKS.append(dict(id=tid, group=group, prompt=prompt, check=check, think=think))


# --- Japanese: keigo (8) -----------------------------------------------------
K = [
    ("先生はもう映画を見ましたか。", ["ご覧になりましたか"]),
    ("お客様がこちらを見ている。", ["ご覧になって"]),
    ("部長が報告書を見ました。", ["ご覧になりました"]),
    ("社長は毎朝新聞を見ます。", ["ご覧になります", "お読みになります"]),
    ("先生、この写真を見てください。", ["ご覧ください", "ご覧になってください"]),
    ("私が資料を見ます。", ["拝見します", "拝見いたします"]),
    ("明日、私がそちらに行きます。", ["伺います", "参ります", "お伺いします"]),
    ("社長が来ました。", ["いらっしゃいました", "ご来社になりました", "お見えになりました", "お越しになりました", "おいでになりました"], ["参りました"]),
]
for i, (src, acc, *rej) in enumerate(K, 1):
    p, c = keigo(src, acc, rej[0] if rej else ())
    add(f"K{i}", "keigo", p, c)

# --- Japanese: knowledge and reading (10) -------------------------------------
add("J1", "ja", "「役不足」という言葉の本来の意味を一文で説明してください。", None)
add("J2", "ja", "「確信犯」という言葉の本来の意味を一文で説明してください。", None)
add("J3", "ja", "ことわざ「情けは人のためならず」の本来の意味を一文で説明してください。", None)
add("J4", "ja", "「相殺」の読みをひらがなで答えてください。" + ANS, answer_is(["そうさい"]))
add("J5", "ja", "「凡例」の読みをひらがなで答えてください。" + ANS, answer_is(["はんれい"]))
add("J6", "ja", "「漸次」の読みをひらがなで答えてください。" + ANS, answer_is(["ぜんじ"]))
add("J7", "ja", "源頼朝が征夷大将軍に任命されたのは西暦何年ですか。" + ANS, answer_is(["1192"]))
add("J8", "ja", "日本で流域面積が最も大きい川は何ですか。" + ANS, answer_is(["利根川"]))
add("J9", "ja", "「彼は彼女ほど背が高くない」という文で、背が高いのはどちらですか。" + ANS,
    answer_is(["彼女"]))
add("J10", "ja", "次の文の敬語の誤りを直した文を答えてください。\n\nお客様が申されたとおりにいたします。" + ANS,
    answer_is(["おっしゃった", "おっしゃられた"]))

# --- Reasoning (6), run with and without thinking ----------------------------
R = [
    ("1から10000までの整数のうち、3または5で割り切れ、かつ7では割り切れないものはいくつありますか。",
     ["4001"]),
    ("30段の階段を、1回に1段・2段・3段のいずれかで上ります。上り方は何通りありますか。", ["53798080"]),
    ("x0 = 7 とし、x(n+1) = (x(n)^2 + 3·x(n) + 1) mod 1009 で数列を定めます。x20 はいくつですか。",
     ["335"]),
    ("A、B、C、Dの4人が、左から1〜4番の席に一列に座っています。4人の職業は教師・医師・料理人・画家で、"
     "全員異なります。\n- AとBは隣り合っている\n- 医師は端の席にいる\n- Bは端の席ではない\n"
     "- Cは画家でも医師でもない\n- 料理人は教師のすぐ右の席にいる\n- Dは2番の席にいる\n"
     "- Aは教師ではない\n- 画家はCより右の席にいる\n\n医師と画家はそれぞれ誰ですか。"
     "「答え: 医師=?, 画家=?」の形で答えてください。",
     ["医師=A画家=B"]),
    ("公平なサイコロ2個を同時に振ることを3回繰り返します。目の和が7になる回が少なくとも1回ある確率を、"
     "既約分数で答えてください。", ["91/216"]),
    ("2024年2月15日から2026年10月10日までは何日ありますか（2024年2月15日を0日目として、"
     "2026年10月10日が何日目か）。また2026年10月10日は何曜日ですか。"
     "「答え: <日数>日, <曜日>」の形で答えてください。", ["968日土曜"]),
]
for i, (q, keys) in enumerate(R, 1):
    for think in (False, True):
        add(f"R{i}" + ("t" if think else ""), "reason", q + ANS, answer_is(keys), think)

# --- Coding (8), hidden tests, run with and without thinking ------------------
CODE = "\n\nPythonで実装し、コードを1つの```pythonブロックにまとめてください。標準ライブラリのみ使用してください。"
C = [
    ("merge_intervals", "閉区間のリスト intervals (list[list[int]]) を受け取り、重なる区間（端点が接する場合も含む）"
     "を併合して開始点の昇順で返す関数 merge_intervals(intervals) を書いてください。"),
    ("LRUCache", "容量 capacity を持つ LRU キャッシュのクラス LRUCache を書いてください。get(key) は値か -1 を返し、"
     "put(key, value) は挿入または更新し、容量を超えたら最も長く使われていないキーを削除します。どちらも O(1) にしてください。"),
    ("calculate", "文字列の算術式を評価する関数 calculate(s) -> int を書いてください。非負整数、+ - * /、括弧、空白、"
     "単項マイナス（例: \"-(2+3)\", \"2*-3\"）を含みます。/ は 0 方向への切り捨ての整数除算です。eval は使わないでください。"),
    ("longest_valid_parentheses", "'(' と ')' だけからなる文字列 s で、正しく対応の取れた最長の部分文字列の長さを返す関数 "
     "longest_valid_parentheses(s) -> int を書いてください。"),
    ("is_match", "'.'（任意の1文字）と '*'（直前の要素の0回以上の繰り返し）に対応した正規表現マッチを、文字列全体に対して行う"
     "関数 is_match(s, p) -> bool を書いてください。re モジュールは使わないでください。"),
    ("min_window", "文字列 s と t が与えられたとき、t の全文字（重複も数える）を含む s の最短の部分文字列を返す関数 "
     "min_window(s, t) -> str を書いてください。存在しなければ空文字列、最短が複数あれば最も左のものを返します。"),
    ("course_order", "n 個の科目 0..n-1 と、[a, b]（a を取る前に b が必要）の前提条件リスト prereqs が与えられます。"
     "全科目を取れる順序を1つ返す関数 course_order(n, prereqs) -> list[int] を書いてください。循環があれば [] を返します。"),
    ("sliding_median", "整数リスト nums と窓幅 k に対し、各窓の中央値を float のリストで返す関数 sliding_median(nums, k) を"
     "書いてください。k が偶数のときは中央2要素の平均です。n=10^5 でも十分速く動くようにしてください。"),
]
for i, (name, q) in enumerate(C, 1):
    for think in (False, True):
        add(f"C{i}" + ("t" if think else ""), "code", q + CODE, ("code", name), think)

# --- Free-form (3), judged blind ------------------------------------------------
PASSAGE = open(__file__.replace("tasks.py", "passage.txt"), encoding="utf-8").read()
add("F1", "free", "書き込みが多いワークロードで、B-tree と LSM-tree のどちらを選ぶべきかを、書き込み増幅・読み出し"
    "増幅・空間増幅・コンパクションの影響に触れながら、日本語で600字程度で説明してください。", None)
add("F2", "free", "次の文章を、要点3つの箇条書きで日本語で要約してください。\n\n" + PASSAGE, None)
add("F3", "free", "Python で、スレッドセーフなトークンバケット方式のレートリミッタのクラスを実装してください。"
    "容量と毎秒の補充レートを指定でき、acquire(tokens=1, timeout=None) がトークンを得られるまで待つ（timeout で諦める）"
    "ようにし、単体テストも付けてください。", None)
