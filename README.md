# MacBonDriver

macOS 向けのユーザーランド USB デジタル放送チューナードライバ（`.bundle`）仕様とリファレンス実装です。
Windows の BonDriver（`IBonDriver` / `IBonDriver2` / `IBonDriver3`）に相当するプラグイン機構を、
macOS の Loadable Bundle（`NSBundle` + Objective-C `@protocol`）として定義します。

## 構成

- [`include/MacBonDriver.h`](include/MacBonDriver.h): SDK ヘッダー（単一ヘッダー・Foundation のみ依存）
  - コアプロトコル: `@protocol MacBonDriver`（`IBonDriver` + `IBonDriver2` 相当）
  - 拡張プロトコル:
    - `@protocol MacBonDriverMultiTuner`（複数チューナー・デバイス列挙 / `IBonDriver3` 相当）
    - `@protocol MacBonDriverLNBControl`（LNB 給電制御 / `IBonDriver3` 相当）
    - `@protocol MacBonDriverTSMF`（BS/CS Stream ID・CATV ISDB-C TSMF 相対 TS 選択）
    - `@protocol MacBonDriverSmartCard`（チューナー内蔵カードリーダー APDU 通信）
    - `@protocol MacBonDriverDelegate`（USB ホットプラグ・ロック変化・バッファ溢れ通知）
- [`docs/SPEC.md`](docs/SPEC.md): MacBonDriver v1.0 仕様書
- [`samples/sample_driver/`](samples/sample_driver): サンプル `.bundle` ドライバ（`MBD_SampleUSB.bundle`）
- [`samples/sample_host/`](samples/sample_host): サンプルホスト & 適合性テスト CLI（`mbd-host`）

## ビルドと動作確認

Xcode または Xcode Command Line Tools が必要です。

```sh
make test
```

個別コマンド:

```sh
# サンプルドライバ (build/MBD_SampleUSB.bundle) とホスト CLI (build/mbd-host) をビルド
make

# バンドル情報とチューニング空間・チャンネル一覧を表示
./build/mbd-host --info build/MBD_SampleUSB.bundle

# 仕様適合性テストを実行
./build/mbd-host --conformance build/MBD_SampleUSB.bundle
```

## ライセンス

[MIT License](LICENSE)
