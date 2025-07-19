# MQTT v5 Server Redirection

## 概要

MQTT v5 Server Redirection機能は、EMQXブローカーが特定の条件下でクライアントを他のサーバーにリダイレクトすることを可能にします。この機能は、現在のサーバーが最大接続数に達した場合や、負荷分散の目的で使用されます。

さらに、この機能はすべてのCONNACKパケットにEMQXクラスタの各ノードのIPアドレス情報を含むServer-Referenceプロパティを自動的に追加します。これにより、クライアントは利用可能なクラスタノードを発見し、ロードバランシングやフェイルオーバーシナリオで使用できます。

## 機能

- **自動リダイレクト**: 設定された条件（例：最大接続数）に達した場合、クライアントを他のサーバーに自動的にリダイレクト
- **複数サーバー対応**: 複数のリダイレクト先サーバーを設定可能
- **リダイレクト戦略**: ランダム選択とラウンドロビン選択をサポート
- **MQTT v5準拠**: MQTT v5プロトコルのServer-Referenceプロパティを使用
- **クラスタノード発見**: すべてのCONNACKパケットにクラスタ内の全ノードのIPアドレス情報を自動的に含める
- **IPv4/IPv6対応**: IPv4とIPv6アドレスの両方をサポート

## 設定

### 基本設定

```hocon
server_redirection {
    ## 機能を有効にする
    enable = true

    ## リダイレクト先サーバーのリスト
    redirect_servers = [
        {
            host = "server1.example.com"
            port = 1883
            description = "Primary backup server"
        },
        {
            host = "server2.example.com"
            port = 1884
            description = "Secondary backup server"
        }
    ]

    ## リダイレクト戦略
    redirect_strategy = random

    ## 最大接続数（この数に達するとリダイレクトが開始される）
    max_connections = 1000
}
```

### 設定パラメータ

| パラメータ | 型 | デフォルト | 説明 |
|-----------|----|-----------|------|
| `enable` | boolean | false | 機能の有効/無効 |
| `redirect_servers` | array | [] | リダイレクト先サーバーのリスト |
| `redirect_strategy` | enum | random | リダイレクト戦略（random/round_robin） |
| `max_connections` | integer | 1000 | 最大接続数 |

### サーバー設定

| パラメータ | 型 | デフォルト | 説明 |
|-----------|----|-----------|------|
| `host` | string | - | サーバーのホスト名またはIPアドレス（必須） |
| `port` | integer | 1883 | サーバーのポート番号 |
| `description` | string | "" | サーバーの説明（オプション） |

## Server Reference プロパティ

### 概要

Server Referenceプロパティは、MQTT v5のCONNACKパケットに含まれるUTF-8エンコードされた文字列です。このプロパティには、クライアントが接続できる利用可能なサーバーのリストが含まれます。

### フォーマット

Server Referenceの値は、スペースで区切られた参照のリストです。各参照は以下の形式で表現されます：

- **IPv4アドレス**: `hostname:port` または `ip:port`
- **IPv6アドレス**: `[ipv6]:port`

### 例

```
127.0.0.1:1883
192.168.1.100:8883
[2001:db8::1]:1883
myserver.example.com:1883
```

### クラスタ環境での動作

EMQXクラスタ環境では、Server Referenceプロパティに以下の情報が自動的に含まれます：

1. **クラスタ内の全ノードのIPアドレス**: 実行中のすべてのEMQXノードのリスナー情報
2. **自動更新**: ノードの追加・削除時に自動的に更新
3. **フォールバック**: RPC呼び出しが失敗した場合でも、ローカルノードの情報は含まれる

### クライアント側での利用

クライアントは、CONNACKパケットからServer Referenceプロパティを読み取り、以下の用途で使用できます：

- **ロードバランシング**: 複数のサーバー間で接続を分散
- **フェイルオーバー**: 現在のサーバーが利用できない場合の代替サーバー
- **地理的分散**: 地理的に近いサーバーへの接続

## 使用方法

### 1. 設定ファイルでの設定

`emqx.conf`ファイルに以下の設定を追加：

```hocon
server_redirection {
    enable = true
    redirect_servers = [
        {
            host = "backup1.emqx.io"
            port = 1883
        },
        {
            host = "backup2.emqx.io"
            port = 1883
        }
    ]
    redirect_strategy = random
    max_connections = 500
}
```

### 2. 環境変数での設定

```bash
export EMQX_SERVER_REDIRECTION__ENABLE=true
export EMQX_SERVER_REDIRECTION__MAX_CONNECTIONS=500
export EMQX_SERVER_REDIRECTION__REDIRECT_STRATEGY=random
```

### 3. HTTP APIでの設定

```bash
# 設定を更新
curl -X PUT http://localhost:18083/api/v5/config/server_redirection \
  -H "Content-Type: application/json" \
  -d '{
    "enable": true,
    "redirect_servers": [
      {
        "host": "backup1.emqx.io",
        "port": 1883
      }
    ],
    "max_connections": 500
  }'
```

## 動作原理

1. **接続監視**: EMQXは現在の接続数を継続的に監視します
2. **条件チェック**: 設定された`max_connections`に達した場合、リダイレクト機能が有効になります
3. **リダイレクト実行**: 新しい接続試行に対して、CONNACKパケットに`Server-Reference`プロパティを含めて返信します
4. **クライアント処理**: MQTT v5クライアントは`Server-Reference`プロパティを受け取り、指定されたサーバーに再接続します

## リダイレクト戦略

### Random（ランダム）
- リダイレクト先サーバーをランダムに選択
- 負荷分散に適している

### Round Robin（ラウンドロビン）
- リダイレクト先サーバーを順番に選択
- より均等な負荷分散を実現

## 制限事項

- MQTT v5プロトコルのみサポート
- クライアントが`Server-Reference`プロパティを処理できる必要がある
- リダイレクト先サーバーが利用可能である必要がある

## トラブルシューティング

### よくある問題

1. **リダイレクトが動作しない**
   - クライアントがMQTT v5をサポートしているか確認
   - リダイレクト先サーバーが利用可能か確認

2. **設定が反映されない**
   - EMQXを再起動
   - 設定ファイルの構文を確認

3. **接続エラー**
   - リダイレクト先サーバーのネットワーク接続を確認
   - ファイアウォール設定を確認

### ログ確認

```bash
# EMQXログでリダイレクト関連のメッセージを確認
tail -f log/emqx.log | grep server_redirection
```

## 関連情報

- [MQTT v5仕様](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html)
- [EMQX設定ガイド](../configuration/configuration.md)
- [EMQX HTTP API](../admin/api-docs.md) 