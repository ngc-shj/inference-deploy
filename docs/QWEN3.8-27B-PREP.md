# Qwen3.8-27B — 事前検証と実行準備 (z1mn / gx10-a9c0)

両機ともオフライン (Tailscale 上で last seen ~1日前) のため、以下は
**モデルカードと本リポジトリの既測値からの机上検証** — 実測ではない。
復帰後の実行手順は §4、llama.cpp のビルド要件は §6。

調査日: 2026-08-16。upstream の issue 状況は動くので、実行前に §6.3 を再確認すること。

---

## 0. 結論 (先に)

| 箱 | 第一候補 | 形式 | サイズ | 理由 |
| --- | --- | --- | --- | --- |
| **gx10-a9c0** (DGX Spark GB10) | `Qwen/Qwen3.8-27B-FP8` または NVFP4 | FP8 / NVFP4 + vLLM | ~28GB / ~20GB | Blackwell ネイティブ FP4、MTP spec-decode が効く唯一の経路 |
| **z1mn** (M5 Max 128GB) | `mlx-community/Qwen3.8-27B-mxfp4` | MLX mxfp4 | 15.2 GB | 既測 (EVALUATIONS-macos.md) で mxfp4 が MLX 最速 |

**ただし最大の論点は形式ではない — このモデルが 27B dense である点。**

---

## 1. アーキテクチャ (これが全てを決める)

[Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B) より:

- **dense 27B** (MoE ではない) → active params = 27B
- 64 層 hybrid: 48 × Gated DeltaNet (linear attn) + 16 × Gated Attention
- Gated Attention: Q 24 heads / KV 4 heads / head_dim 256
- native ctx 262144 (RoPE scaling で 1M)
- MTP head あり、`reasoning_effort` (xhigh/medium/low) 対応
- sampling: thinking `temp 1.0 / top_p 0.95 / top_k 20`、
  instruct `temp 0.7 / top_p 0.80 / top_k 20`

### 帯域則からの予測 — ここが重要

本リポジトリの既測値 (EVALUATIONS.md 2026-06-21) では、**同じ 27B dense +
hybrid の Qwen3.6-27B が GB10 で 24.4 tok/s**、常駐の 35B-A3B (MoE, active 3B)
が 90.5 tok/s。3.5倍差は構造的なもので、warm-up ではないと再確認済み。

Qwen3.8-27B は同じ 27B dense。**active bytes が Q4 で ~17-18 GB あるため、
GB10 では 25-30 tok/s 級になるはず** — 常駐 35B-A3B より大幅に遅い。
Ternary-Bonsai-27B (1.6bit, 6.7GB) ですら 25.7 tok/s だったことから、
27B dense には量子化では越えられない天井がある (EVALUATIONS.md 2026-07-20)。

M5 Max は帯域 ~546 GB/s と GB10 の 2倍なので、mxfp4 15.2 GB なら
**50-70 tok/s 程度**が期待値 (35B-A3B mxfp4 が 138-140 tok/s、
active bytes が約 4-5 倍なので相応に落ちる)。

→ **速度目的なら採用理由はない。品質が 35B-A3B を明確に上回るかどうかが
唯一の判断軸。** 検証はそこに絞るべき。

---

## 2. 量子化の選択

### gx10-a9c0 (GB10)

[vLLM 公式レシピ](https://recipes.vllm.ai/Qwen/Qwen3.8-27B) が最も信頼できる:

```
vllm serve Inferact/Qwen3.8-27B-NVFP4 \
  --tensor-parallel-size 1 --max-model-len 262144 \
  --kv-cache-dtype fp8 --reasoning-parser qwen3 \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder
```
MTP は `--speculative-config '{"method":"mtp","num_speculative_tokens":3}'`。

- 最小 vLLM 0.17.0+ (NVIDIA ModelOpt NVFP4 は 0.24.0+ という記述もあり、
  **本リポジトリの実績どおり `vllm/vllm-openai:nightly` を使うのが安全**)
- レシピ記載の NVFP4 は `Inferact/...`。提示された `unsloth/Qwen3.8-27B-NVFP4`
  は Unsloth Dynamic V3.0 (preview) で、カードに vLLM バージョン要件の記載なし
  → **未知数。まず公式 `Qwen/Qwen3.8-27B-FP8` で動かし、その後 NVFP4 を試す**
  のが手戻りが少ない
- **⚠ MXFP4 は NVIDIA 上で使うな** — レシピの Known Issues に明記:
  「vLLM の MXFP4 実装は NVIDIA デバイスで linear method support が欠けており
  意図どおり動かない。NVIDIA では NVFP4 を使え」

FP8 (`Qwen/Qwen3.8-27B-FP8`) は block size 128 の fine-grained fp8、
~28GB。品質は「ほぼオリジナルと同一」。128GB プールには余裕。

### z1mn (M5 Max)

既測の格付け (EVALUATIONS-macos.md): **mxfp4 ≈ 4bit > nvfp4**。
MLX には NVFP4 のハード経路がないため、常駐バイト数がそのまま速度になる。

- `mlx-community/Qwen3.8-27B-mxfp4` — **15.2 GB、第一候補**
- `mlx-community/Qwen3.8-27B-4bit` — 同等の代替
- `mlx-community/Qwen3.8-27B-8bit` / `-bf16` — 品質比較用 (帯域的に遅い)
- **NVFP4 safetensors (unsloth/nvidia) は MLX にロードできない** — 既知
  (mlx-lm の quant dispatch に modelopt 分岐がない)。MLX ネイティブ変換のみ

---

## 3. 復帰後に確認すべき「詰まりどころ」(机上では解けない)

優先度順。**どれも当日ハマる可能性があるもの。**

1. **vllm-mlx が Qwen3.8 を読めるか** — 最大のリスク。
   `mlx-community/Qwen3.8-27B-mxfp4` のカードは **`mlx-vlm` (VLM 用)** を
   loader に指定しており、これは実績のある `vllm-mlx` / `mlx-lm` 経路とは別。
   モデルは vision 対応 (unsloth GGUF にも `mmproj-*.gguf` がある)。
   vllm-mlx の models.md には Qwen3.5/3.6/3.8 の記載がない — ただし
   **これは資料が古いだけの可能性が高い** (0.4.0 で `qwen3_5_moe` を実測済み)。
   → 当日 `vllm-mlx serve` を叩いて確認。落ちたら `mlx-vlm` へ切替。

2. **transformers ピン** — 既知の地雷。bare mlx-lm は transformers 5.0.0、
   vllm-mlx 0.4.0 は 5.12.1 で動いた。Qwen3.8 で再度ずれる可能性あり。
   venv は分離済みなので影響は局所化される。

3. **llama.cpp のバージョン** — 詳細は §6 (実際の upstream issue を調査済み)。

4. **GGUF の MTP** — unsloth リポジトリのファイル一覧には MTP ファイルが無いが、
   **`--spec-type draft-mtp` は unsloth の GGUF で実際に動いている**
   (upstream issue #27122 の再現構成が `Qwen3.8-27B-UD-Q4_K_XL` + `draft-mtp`)。
   MTP テンソルは本体 GGUF に埋め込まれている = Qwen3.6-35B と同じ扱いでよい。
   [ggml-org 版](https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF) の
   別ファイル MTP (Q8_0 MTP 3.16GB 等) は別配布形態。unsloth 版を使うなら不要。

5. **MLX の MTP も sidecar** — `mlx-community/Qwen3.8-27B-MTP-4bit` は
   239 MB の drafter 単体 (`model_type: qwen3_5_mtp`, MTP block size 3)。
   単独では動かず、ターゲット checkpoint と組で使う。
   `--draft-kind mtp` は model_type から自動検出、とカードにある。

---

## 4. 実行手順 (NW 復帰後)

### 4.1 事前ダウンロード (両機、NW 復帰直後に流す)

帯域を食うので検証より先に走らせておく。

```bash
# z1mn
huggingface-cli download mlx-community/Qwen3.8-27B-mxfp4

# gx10-a9c0
huggingface-cli download Qwen/Qwen3.8-27B-FP8
```

### 4.2 gx10-a9c0 — vLLM

`/etc/vllm/vllm-server.env` を編集 (本リポジトリの `vllm-server.env.example`
の NVFP4 例が下敷きになる):

```sh
VLLM_IMAGE="vllm/vllm-openai:nightly"
VLLM_MODEL="Qwen/Qwen3.8-27B-FP8"
VLLM_SERVE_ARGS="--kv-cache-dtype fp8 --gpu-memory-utilization 0.5 --max-model-len 262144 --reasoning-parser qwen3 --enable-auto-tool-choice --tool-call-parser qwen3_coder"
VLLM_SPEC_CONFIG='{"method":"mtp","num_speculative_tokens":3}'
```

`sudo systemctl start vllm-server` (llama-server は Conflicts= で自動停止)。
まず MTP なし (`VLLM_SPEC_CONFIG=''`) で起動確認 → 動いたら MTP を足す、の順が安全。

### 4.3 z1mn — vllm-mlx

`~/.config/vllm-mlx/vllm-mlx-server.env`:

```sh
VLLM_MLX_MODEL="mlx-community/Qwen3.8-27B-mxfp4"
VLLM_MLX_ARGS="--host 127.0.0.1 --port 8000 --reasoning-parser qwen3"
```
`NO_BUILD=1 ./install.sh` で plist 再生成 + reload。
起動失敗時は `~/.local/state/vllm-mlx/logs/vllm-mlx-server.err.log` を見る。

### 4.4 測定 (既存の評価と接続可能にする)

**既存の evaluation と比較可能にするため、プロンプトと条件を揃えること**:
- 同じ coding タスク (`merge_intervals` doctest / bugfix / refactor)
- `enable_thinking: false`、temp 0.7 / top_p 0.80 / top_k 20 (instruct)
- 1回目は load+warmup 支配なので捨て、2-3 回目を採用
- single-shot decode tok/s

比較対象: 常駐 `Qwen3.6-35B-A3B-MTP:Q4_K_XL` (GB10 77.8/63.3 tok/s、
M5 Max mxfp4 138-140 tok/s)。

---

## 5. 検証の主眼 (速度ではなく品質)

前述のとおり 27B dense は両機で 35B-A3B より遅いことがほぼ確実。
したがって「採用するか」の判断は品質で決まる。既存の toy coding タスクは
**Qwen3.6-27B / Ornith / Coder-Next のいずれでも差が出なかった** (全て 3/3 pass)
ので、同じ手を繰り返しても判断材料にならない。

→ より弁別力のあるタスクを用意すべき:
- `reasoning_effort` (xhigh/medium/low) の効き方 — Qwen3.8 の新機能で、
  35B-A3B にはない軸。ここは実際に差が出る可能性がある
- 実エージェントループ (Ornith で使った RPN calculator のような
  read→edit→run→verify) — toy 生成より弁別力が高いと実証済み
- long-context (262144) の実挙動

---

## 6. llama.cpp 最新ビルド — 詳細

### 6.1 結論: アーキテクチャは既にサポート済み。「読めない」わけではない

当初「最新ビルド必須、既存ビルドでは読めない公算」と書いたが、これは
ブログ記事ベースの推測だった。**upstream を直接調べた結果、状況はより明確**:

- Qwen3.8-27B の GGUF arch は **`qwen35`** — Qwen3.5/3.6 系と同じ実装を共有する。
  本リポジトリが既に常駐させている `Qwopus3.5-9B-v3` も `qwen35` (README.md 参照)
- `GGML_OP_GATED_DELTA_NET` は **CUDA / Metal / Vulkan いずれも実装済み**
  (#19504 op 追加 → #20244 Metal backend, #20361 Metal GDN kernel, #20334 Vulkan、
  いずれも **closed = マージ済み**)
- MTP spec-decode も #22673 でマージ済み

つまり**新規アーキテクチャの追加待ちではない**。既存ビルドが古すぎれば
`unknown model architecture` で落ちるが、`qwen35` を既に動かせているビルドなら
ロード自体は通る可能性が高い。**問題は「読めるか」ではなく「バグを踏むか」。**

### 6.2 現行バージョン (2026-08-16 時点)

- 最新リリースタグ: **b10442** (2026-08-15)
- master HEAD: `ad1de39e0`

### 6.3 実際に報告されている Qwen3.8-27B 固有の不具合 (すべて open)

**ここが最新ビルドを推す本当の理由。** 直近数日に集中して報告されている:

| Issue | 内容 | 該当条件 | 我々への影響 |
| --- | --- | --- | --- |
| [#27090](https://github.com/ggml-org/llama.cpp/issues/27090) | YaRN ×4 で ~520K prefill 時に**無言で落ちる** (2×yarn-orig-ctx 直下) | rope-scale 4 で 1M ctx 狙い | **native 262144 なら無関係** |
| [#27122](https://github.com/ggml-org/llama.cpp/issues/27122) | `draft-mtp` + `--split-mode tensor` で**CUDA ロックアップ** | 複数 GPU 分割時 | **GB10 は単一GPUなので無関係** |
| [#27107](https://github.com/ggml-org/llama.cpp/issues/27107) (closed) | chat template の `raise_exception` で Claude Code / Codex が **400 で即死** | `--jinja` + 複数 system prompt | **該当しうる** |
| [#27139](https://github.com/ggml-org/llama.cpp/issues/27139) | Codex エラー、Qwen3.6 の template で回避 | 同上 | 同上 |
| [#27023](https://github.com/ggml-org/llama.cpp/issues/27023) | `reasoning_effort` が壊れている疑い | reasoning 制御 | **§5 の検証主眼に直撃** |
| [#27109](https://github.com/ggml-org/llama.cpp/issues/27109) | qwen35 hybrid で **4bit KV cache が prefill を ~34 t/s に落とす** | `-ctk/-ctv q4_*` | q8_0 なら回避 |

**#27090 の重要な副次情報**: 「~90-100K 超のプロンプトが b10430 で同様にクラッシュ
していたが **b10434 で修正された**」(#26623 recurrent state rollback)。
→ **b10434 未満のビルドは long-context で実用にならない。最低 b10434、
できれば b10442 以降を使うこと。** これが「最新ビルドが必要」の具体的な根拠。

### 6.4 我々の構成で踏むもの / 踏まないもの

**踏まない** (幸い、報告されている重大不具合の大半は条件が合わない):

- #27090 → YaRN を使わず native 262144 で運用すれば無関係
- #27122 → GB10 も M5 Max も**単一デバイス**、`--split-mode tensor` を使わない
- #27109 → KV 量子化は q8_0 を使う方針 (models.ini のコメント通り)。q4 は避ける

**踏む可能性が高い**:

- **chat template の `raise_exception`** — llama.cpp の autoparser (#18675) が
  合成メッセージ列で template を probe するが、Qwen3.5 系 template は
  「System message must be at the beginning」を assert するため
  **パーサ生成に失敗して 400**。llama.cpp #20733 は not planned で closed、
  つまり**上流では直らない**。回避策は 2つ:
  1. Unsloth が配布する修正済み template を `--chat-template-file` で渡す
  2. Qwen3.6 の template を流用する (#27139)
- **`reasoning_effort` (#27023)** — §5 で検証主眼に据えた軸そのものなので、
  llama.cpp 経由で評価すると llama.cpp のバグを測ってしまう恐れがある。
  → **reasoning_effort の評価は vLLM / vllm-mlx 側で行うのが安全**

### 6.5 ビルド手順

**gx10-a9c0 (CUDA)** — 本リポジトリの `install.sh` がそのまま使える。
既存の checkout は「触らない」設計 (`install.sh` は clone のみ、pull しない)
なので、**明示的に更新してから**再ビルドする:

```bash
cd ~/ghq/github.com/ggml-org/llama.cpp
git fetch origin && git checkout b10442      # または master
cd ~/ghq/github.com/ngc-shj/inference-deploy/llama.cpp
./install.sh                                  # CUDA_ARCH=121 は既定
sudo systemctl restart llama-server
/opt/llama/bin/llama-server --version         # build 番号を確認
```

**z1mn (Metal)** — このリポジトリに Metal 版の install.sh は無い。
EVALUATIONS-macos.md に記録された手順に従う:

```bash
cmake -S llama.cpp -B build-metal -DGGML_METAL=ON -DLLAMA_CURL=ON
cmake --build build-metal --target llama-server -j
```

ただし z1mn 側は **vllm-mlx (MLX) が llama.cpp/Metal より ~1.5倍速い**と
実測済み (129 vs 87 tok/s) なので、**llama.cpp をビルドする必要は薄い**。
GGUF 限定の用途か、llama.cpp 固有機能が要る場合のみ。

### 6.6 まとめ — なぜ最新ビルドなのか

「Gated DeltaNet が未実装だから」ではない (実装済み)。理由は:

1. **b10434 で long-context のクラッシュが修正された** — それ未満は実用外
2. Qwen3.8-27B 固有の不具合が**現在進行形で報告・修正されている**
   (直近 2日で 4件 open) ため、古いビルドほど地雷が多い

---

## 参考

- [Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B)
- [Qwen/Qwen3.8-27B-FP8](https://huggingface.co/Qwen/Qwen3.8-27B-FP8)
- [unsloth/Qwen3.8-27B-GGUF](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF)
- [unsloth/Qwen3.8-27B-NVFP4](https://huggingface.co/unsloth/Qwen3.8-27B-NVFP4)
- [ggml-org/Qwen3.8-27B-GGUF](https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF)
- [mlx-community/Qwen3.8-27B-mxfp4](https://huggingface.co/mlx-community/Qwen3.8-27B-mxfp4)
- [mlx-community/Qwen3.8-27B-MTP-4bit](https://huggingface.co/mlx-community/Qwen3.8-27B-MTP-4bit)
- [vLLM Recipes — Qwen3.8-27B](https://recipes.vllm.ai/Qwen/Qwen3.8-27B)
- 既測値: `llama.cpp/EVALUATIONS.md`, `llama.cpp/EVALUATIONS-macos.md`
