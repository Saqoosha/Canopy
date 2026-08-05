# ペイン並べ替え設計

サイドバーの open 行をドラッグして、マルチペインの左右位置を入れ替えられるようにする。

## 原則

ユーザーのドラッグ以外で、行もペインも動かない。

この機能は「サイドバーの並び順とペインの並び順を常に一致させる」不変条件としても書けるが、その形は採らない。不変条件を維持しようとすると、ペイン割り当てが変わるたびにサイドバーの行が勝手に動く。とくに `cycleFocusedPaneSession`（Cmd+Shift+[/]）は `openInFocusedPane` を素通しで呼ぶため、セッションを巡回するだけで行が次々に引きずられる。ペインを増やしたときに要素が勝手に右へ飛ぶ挙動も同じ理由で却下された。

代わりに、ドラッグという明示的な操作のときだけペインを動かす。ドラッグ以外の経路ではサイドバー順とペイン順のズレを許容する。ズレは `Sidebar.swift:317` の `highlight(for:)` による背景色で見えているので、ユーザーが読み取れる。

## 変更点

2 箇所。

### 1. open 行の Cmd+click を単なるクリックとして扱う

`Sidebar.handleRowClick` の `.open` 分岐で `addNewPane` を無視し、常に `store.openInFocusedPane(session.id)` を呼ぶ。

既にペインにあるセッションならそのペインにフォーカスが移り、なければフォーカス中のペインに読み込まれる。どちらも `openInFocusedPane` の既存分岐そのままで、新しい挙動は足さない。

これにより、既に開いているセッションを Cmd+click してペインを右端に生やす経路が消える。ペインが増えるのは新しいセッションを開くときだけになり、そのとき `openSessions.append` と右端へのペイン追加が同時に起きるため、生まれた瞬間は必ず順序が一致する。

`bouncePane(forSessionId:)` はこの分岐からしか呼ばれていないため、デッドコードとして削除する。

### 2. ドラッグでペインを追従させる

`SessionStore.moveOpenSessions` の末尾で、ドラッグされたセッションのペインだけを新しい位置へ移す。

```
openSessions:  A  B  C  D          panes: [A][B][C]
C を B の上へドラッグ
openSessions:  A  C  B  D    →     panes: [A][C][B]
```

アルゴリズム。

1. `fromOffsets` を visible 座標から解決し、ドラッグされたセッション id の集合を得る
2. 並べ替え後の `openSessions` において、ペインを持つセッションだけを取り出した並びを作る
3. ドラッグされた id のうちペインを持つものについて、その並びでの順位を求める
4. その id の `PaneSlot` を、session ペインが占めるスロット位置の集合の中で、その順位に対応する位置へ移す

全体の再ソートはしない。動くのはドラッグされたペインだけ。これはズレが溜まった状態でドラッグしたとき、意図より大きくペインが飛ぶのを防ぐためにある。

補足規則。

- ペインを持たない行をドラッグした場合は何も起きない。ペイン付きの行をペインなしの行を跨いでドラッグした場合も、ペイン同士の相対順が変わらなければ何も起きない。色付き行の並びが変わらないことが、そのまま「何も起きない」の説明になる
- launcher ペインはサイドバー行を持たないため、現在の index に固定する。session ペインはそれらの隙間を避けて並べ替わる
- 複数行の同時ドラッグ（`fromOffsets` の要素が 2 つ以上）は、並べ替え後の順に 1 つずつ規則を適用する
- `focusedPaneIndex` は移動後の同じ `PaneSlot.id` を指し直す。フォーカスはスロット位置ではなくセッションに追従する

## 幅とアイデンティティの扱い

移動単位は `PaneSlot` 全体。`content` だけを入れ替えてスロット位置を固定する案は採らない。理由が 2 つある。

幅がセッションに追従する。`preferredWidth` が一緒に動くのでペインの合計幅が変わらず、ウィンドウのリサイズが起きない。各 WKWebView は幅が変化しないまま x 座標だけ移動するため再レイアウトが走らず、チャットのスクロール位置がずれない。

SwiftUI の identity が保たれる。`Detail.swift:113` で `SessionContainer` は `.id(session.id)` を持つ。`PaneSlot` ごと動かせば `ForEach(id: \.element.id)` から見て要素の移動になり、部分木はそのまま運ばれる。逆にスロット位置を固定して `content` だけ交換すると、そのスロットの `.id(session.id)` が別の値に変わり `SessionContainer` が破棄・再構築される。`OpenSession.webView` のキャッシュがあるため致命傷にはならないが、避けられる churn を自分から呼び込むことになる。

`normalizePaneWeightsToVisualWidths()` は呼ばない。この操作は `preferredWidth` を絶対 pt として解釈せず、要素を入れ替えるだけだからである。`schedulePaneResize()` も呼ばない。合計幅が不変でウィンドウを変える理由がない。

## 変更しない点

- UI 追加はゼロ。バッジも、open ブロックの段分けも入れない
- `openInFocusedPane` / `openNew` / `openInNewPane`: サイドバー順を書き換えない。ズレは許容する
- `closePane` / `removePanesForClosedSession`: 要素の削除は相対順を壊さない
- `cycleFocusedPaneSession` / Cmd+Ctrl+1..9: `visibleRows` の open 行順を読む既存実装のまま
- 閉じたセッション行と New Session ボタンの Cmd+click: 新しいセッションを新ペインで開く経路は現状維持

## テスト

`_SidebarLogicProbe` に追加する。プローブは既に `SessionStore` を直接組み立てて `openInNewPane` などを叩いているので、同じ形で書ける。

- 隣接する 2 ペインの入れ替えで `panes` の順が入れ替わる
- 入れ替え後、各 `preferredWidth` が対応するセッションに付いて動いている
- 並べ替え前後で `panes.count` と `preferredWidth` の総和が不変
- ペインなしの open 行を挟んだドラッグがペイン順を変えない
- ペインを持たない行のドラッグがペインを一切変えない
- launcher ペインが index に留まり、その両側の session ペインだけが並べ替わる
- `focusedPaneIndex` が移動後も同じセッションを指す
- ズレた状態（ペイン順とサイドバー順が不一致）でのドラッグが、ドラッグされたペインだけを動かし他を動かさない
- open 行の Cmd+click が `openInFocusedPane` と同じ結果になる（ペインが増えない）

フィルタで隠れた行の扱いは新しいテストを書かない。追従処理は並べ替え後の `openSessions` しか読まず、可視座標からマスター座標への写像は既存の `reorderPreservingHidden`（`_SidebarLogicProbe.swift:918-943` に 6 アサーション）が担保しているため、構造上フィルタに依存しない。

`ci.yml` の `EXPECTED_ASSERTIONS` を、追加後の実測値まで引き上げる。

## リスクと確認事項

`ForEach` の要素移動が SwiftUI 上で本当に移動として扱われ、再マウントにならないことは実機で確認するまで断定しない。上の identity 分析は再マウントが起きない根拠だが、macOS 26 の SwiftUI はマルチペイン周りで既に一度裏切っている（`WeightedPaneLayout` の学びを参照）。実装後、2 ペインを入れ替えてチャットのスクロール位置が保たれることを目視で確認する。

open 行の Cmd+click を無効化することで、既に開いているセッションをもう一枚のペインに出す手段がなくなる。閉じてから開き直せば新ペインで開けるため完全な行き止まりではないが、機能の縮小ではある。
