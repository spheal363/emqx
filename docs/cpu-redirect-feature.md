ｚｚ# CPU使用率に基づくPublisherリダイレクト機能

## 概要

EMQXの新しい機能として、CPU使用率が80%を超えた時に、最もスループットが大きいpublisherを特定し、クラスタ内のCPU使用率が60%未満のノードにServer Redirectionを行う機能を実装しました。

## 機能詳細

### 発動条件
- **CPU使用率**: 80%を超えた場合
- **対象**: 最もスループット（メッセージ数/秒）が大きいpublisher
- **リダイレクト先**: クラスタ内でCPU使用率が60%未満のノード
- **プロトコル**: MQTT v5のServer Referenceプロパティを使用

### 動作フロー

1. **CPU監視**: `emqx_os_mon.erl`でCPU使用率を監視
2. **Publisher特定**: `emqx_publisher_stats.erl`から最もスループットが大きいpublisherを特定
3. **低CPUノード検索**: クラスタ内でCPU使用率が60%未満のノードを検索
4. **Server Redirection**: MQTT v5のDISCONNECTパケットでServer Referenceを送信
5. **クールダウン**: 30秒間のクールダウン期間を設定

### 実装ファイル

#### 主要モジュール
- `apps/emqx/src/emqx_cpu_redirect.erl` - メイン機能モジュール
- `apps/emqx/src/emqx_os_mon.erl` - CPU監視トリガー
- `apps/emqx/src/emqx_sys_sup.erl` - スーパーバイザー設定

#### 拡張モジュール
- `apps/emqx/src/emqx_publisher_stats.erl` - `get_current_second_key/0`関数を追加

#### テスト・ドキュメント
- `apps/emqx/test/emqx_cpu_redirect_SUITE.erl` - テストスイート
- `rel/config/examples/cpu_redirect.conf.example` - 設定例
- `docs/cpu-redirect-feature.md` - このドキュメント

## 設定

### デフォルト設定
```erlang
-define(CPU_HIGH_THRESHOLD, 80). % 80%
-define(CPU_LOW_THRESHOLD, 60).  % 60%
-define(REDIRECT_COOLDOWN, timer:seconds(30)). % 30秒
```

### 設定例
```bash
# ログレベルを調整してリダイレクト情報を確認
log.level = info
```

## 使用方法

### 1. 自動起動
この機能は`emqx_sys_sup.erl`に追加されているため、EMQX起動時に自動的に開始されます。

### 2. 手動制御
```erlang
% リダイレクト処理を手動で実行
emqx_cpu_redirect:maybe_redirect_publisher().

% モジュールを停止
emqx_cpu_redirect:stop().
```

### 3. ログ確認
```bash
# リダイレクト情報を確認
grep "publisher_redirected" /var/log/emqx/emqx.log.1

# エラー情報を確認
grep "failed_to_redirect_publisher" /var/log/emqx/emqx.log.1
```

## 技術仕様

### Server Reference形式
```
"192.168.1.100,192.168.1.101"
```

### スループット計算
- `emqx_publisher_stats:get_publisher_stats/0`から取得
- 直近1秒のpublish数をスループットとして使用
- 最大スループットのpublisherを特定

### CPU使用率取得
- ローカルノード: `emqx_vm:cpu_util/0`
- リモートノード: `erpc:call(Node, emqx_vm, cpu_util, [], 5000)`

### エラーハンドリング
- publisherが見つからない場合
- 低CPUノードが見つからない場合
- ネットワークエラー
- クライアント切断エラー

## 制限事項

1. **MQTT v5のみ対応**: Server ReferenceプロパティはMQTT v5でのみ利用可能
2. **クールダウン期間**: 30秒間のクールダウンで連続リダイレクトを防止
3. **単一チャネル**: 複数チャネルを持つクライアントは未対応
4. **リモートノード**: ネットワーク障害時はリモートノードのCPU情報が取得できない

## トラブルシューティング

### よくある問題

1. **リダイレクトが発生しない**
   - CPU使用率が80%未満であることを確認
   - クールダウン期間（30秒）を確認
   - ログでエラーを確認

2. **Server Referenceが空**
   - クラスタ内にCPU使用率60%未満のノードが存在することを確認
   - ネットワーク接続を確認

3. **クライアントが再接続しない**
   - MQTT v5クライアントであることを確認
   - Server Referenceプロパティを処理できるクライアントであることを確認

### デバッグ方法

```erlang
% 現在のCPU使用率を確認
emqx_vm:cpu_util().

% 全publisherの統計を確認
emqx_publisher_stats:get_publisher_stats().

% クラスタ内ノードを確認
emqx:running_nodes().
```

## 今後の改善点

1. **設定可能な閾値**: 設定ファイルでCPU閾値を調整可能にする
2. **複数チャネル対応**: 複数チャネルを持つクライアントの対応
3. **メトリクス追加**: Prometheusメトリクスでの監視
4. **Webhook通知**: リダイレクト発生時のWebhook通知
5. **負荷分散アルゴリズム**: より高度な負荷分散ロジックの実装 