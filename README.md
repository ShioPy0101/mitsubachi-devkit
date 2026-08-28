# Mitsubachi DevKit

Mitsubachi のローカル開発プロセスを `lx` で一括管理するリポジトリです。本番・Staging、systemd、デプロイ、サーバープロビジョニングを扱う `mitsubachi-infra` とは設定を共有せず、ローカル固有の責務だけを持ちます。

`mitsubachi-ruby`、`mitsubachi-front`、`mitsubachi-infra` のソースは devkit に含めません。既定では次の兄弟配置を自動検出します。

```text
mitsubachi/
├── mitsubachi-ruby/
├── mitsubachi-front/
├── mitsubachi-infra/
└── mitsubachi-devkit/
```

## 初期セットアップ

```bash
git clone git@github.com:ShioPy0101/mitsubachi-devkit.git
cd mitsubachi-devkit

./lx doctor
./lx setup
```

`doctor` は診断専用で、パッケージや依存をインストールしません。初回は未作成の DB や storage を報告して終了コード 1 になることがあります。表示された OS パッケージを手動で用意してから `setup` を実行してください。

`setup` は次を冪等に行います。

- `runtime/{logs,pids,storage/drive_items,tmp,nginx}` の作成
- 未作成の場合だけ `.env.local` と `config/local.yml` をテンプレートから生成
- `bundle check` に失敗した場合だけ `bundle install`
- `node_modules` がない場合だけ `npm install`
- Rails の `db:prepare` による development DB の安全な作成と migration
- ローカル Nginx 設定の生成

OS パッケージのインストール、`db:drop`、`db:reset`、`db:purge` は実行しません。依存のインストールを別途行う場合は `./lx setup --skip-dependencies` も利用できます。

PATH を通す場合:

```bash
export PATH="$PATH:/path/to/mitsubachi-devkit"
```

その後は任意のディレクトリから次を実行できます。

```bash
lx pm start
```

## 通常利用

```bash
lx pm start
lx pm status
lx pm logs
lx pm logs ruby
lx pm stop
```

`start` は設定と production safety を確認し、runtime と Nginx 設定を生成してから、PostgreSQL 接続、`db:prepare`、ruby、front、nginx、mailpit の順で処理します。起動済みサービスは PID、プロセス開始情報、healthcheck を確認してスキップするため、繰り返し実行しても多重起動しません。

`stop` は devkit が記録した PID とプロセス開始情報が一致するプロセスグループだけへ SIGTERM を送ります。タイムアウトした場合のみ SIGKILL へ進みます。OS が管理する PostgreSQL や、別途起動した Rails、Node、Nginx は停止しません。

ログは `runtime/logs/`、プロセス情報は `runtime/pids/`、ローカルファイルは `runtime/storage/` に置かれ、すべて Git 管理外です。

## URL とポート

```text
Frontend
http://127.0.0.1:3000

Rails API (direct)
http://127.0.0.1:3001

Nginx local proxy / file delivery
http://127.0.0.1:8080

Mailpit Web UI
http://127.0.0.1:8025

Mailpit SMTP
127.0.0.1:1025
```

Frontend には `VITE_API_BASE_URL=http://127.0.0.1:8080` を注入します。API リクエストを Nginx 経由にすることで、Rails の `X-Accel-Redirect` を `runtime/storage/drive_items/` の内部配信へ接続し、Range、`206 Partial Content`、`Content-Range` を本番に近い経路で確認できます。

Rails の development mailer は既存どおり Resend を利用します。devkit は `mitsubachi-ruby/.env`、credentials、`RESEND_API_KEY`、`MAIL_FROM` を生成・変更しません。Mailpit は独立したローカル確認用サービスとして起動します。

## 設定

標準設定は `config/devkit.yml`、ローカル上書きは Git 管理外の `config/local.yml` です。コマンドは shell 文字列ではなく argv 配列で定義します。

兄弟配置でない場合は `.env.local` に絶対パスを設定します。

```dotenv
MITSUBACHI_RUBY_ROOT=/work/mitsubachi-ruby
MITSUBACHI_FRONT_ROOT=/work/mitsubachi-front
MITSUBACHI_INFRA_ROOT=/work/mitsubachi-infra
```

ポート等を変える場合の `config/local.yml` 例:

```yaml
services:
  ruby:
    port: 3101
    command: [bin/rails, server, -b, 127.0.0.1, -p, "3101"]
    healthcheck: http://127.0.0.1:3101/api/health/ready
```

関連する Frontend API URL、Nginx port、healthcheck も同時に整合させてください。

## Production safety

起動・setup の前に次を検査し、該当時は `Refusing to start: production configuration detected.` として停止します。

- `RAILS_ENV` が `development` 以外
- DB 名が `mitsubachi_ruby_development` 以外、または DB host が loopback 以外
- storage が devkit の `runtime/storage` 外
- Frontend/API の host または origin が loopback 以外
- SMTP override がある場合に loopback 以外、または認証が有効

Rails へは `RAILS_ENV=development`、development DB URL、devkit 内 storage を明示的に渡します。本番 DB、本番 storage、production secrets、既存 `.env`、credentials は読み書きしません。

## Nginx ファイル配信の検証

Nginx 設定だけを確認する場合:

```bash
nginx -t \
  -p "$PWD/runtime/nginx/" \
  -c "$PWD/runtime/nginx/nginx.conf"
```

疑似 Rails が返す `X-Accel-Redirect` と Range レスポンスを実プロセスで検証する統合テスト:

```bash
ruby -Itest test/nginx_range_test.rb
```

テストは内部 location への直接アクセスが 404 になること、Range が 206、期待した `Content-Range` と部分 body を返すことも確認します。

## Troubleshooting

### PostgreSQL に接続できない

```bash
pg_isready -d postgresql:///postgres
psql postgresql:///mitsubachi_ruby_development -c 'SELECT 1'
```

既存のローカル PostgreSQL service を手動で起動してください。devkit は PostgreSQL 自体を起動・停止・インストールしません。DB がない場合は `lx setup` の `db:prepare` が development DB だけを作成します。

### port already in use

```bash
lsof -nP -iTCP:3000 -sTCP:LISTEN
lsof -nP -iTCP:3001 -sTCP:LISTEN
lsof -nP -iTCP:8080 -sTCP:LISTEN
lsof -nP -iTCP:1025 -sTCP:LISTEN
lsof -nP -iTCP:8025 -sTCP:LISTEN
```

devkit 管理外のプロセスは自動停止しません。所有者を確認して手動停止するか、`config/local.yml` でポートを変更してください。

### stale PID

`lx pm status` または `lx pm start` は PID の存在だけでなく実プロセスと開始情報を確認し、stale な `runtime/pids/*.json` を自動削除します。繰り返し stale になる場合は `runtime/logs/<service>.log` を確認してください。

### nginx config error

`lx pm start` は起動前に `nginx -t` を実行します。生成物は直接編集せず、`config/nginx/nginx.conf.erb` または `config/local.yml` を修正してください。Homebrew 等の system nginx 設定や本番 Nginx 設定は変更しません。

### Ruby dependencies 不足

```bash
cd ../mitsubachi-ruby
bundle check
bundle install
```

Ruby は `mitsubachi-ruby/.ruby-version` と同じ 3.4.9 を利用します。

### Node dependencies 不足

```bash
cd ../mitsubachi-front
npm install
npm run dev -- --host 127.0.0.1 --port 3000 --strictPort
```

Frontend は既存の `package-lock.json` と npm scripts を利用します。

### Mailpit 不在

`lx doctor` の案内に従って Mailpit を手動インストールしてください。devkit は自動インストールしません。`mailpit --version` と 1025/8025 の空きを確認します。

### ffmpeg 不在

ffmpeg はメディア処理用の手動 prerequisite です。devkit はインストールや再インストールを行いません。

```text
macOS:  brew install ffmpeg
Ubuntu: sudo apt install ffmpeg
```

## 開発・テスト

外部 gem を使わず Ruby 標準ライブラリと Minitest で実装しています。

```bash
bin/check
```

主なテスト対象は config parser、兄弟リポジトリ検出、production 拒否、setup、doctor、missing command、起動冪等性、stale PID、stop/restart/status、PID 再利用、port conflict、Nginx Range 配信です。
