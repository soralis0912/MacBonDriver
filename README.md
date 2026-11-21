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
- [`samples/sample_driver/`](samples/sample_driver): 仮想 TS 生成によるリファレンス `.bundle` ドライバ（`MBD_SampleUSB.bundle`）
- [`samples/sqr100_driver/`](samples/sqr100_driver): **PIXELA XIT-SQR100（06b8:106b）** 向け実機 USB ユーザーランド `.bundle` ドライバ（`MBD_SQR100.bundle`、ISDB-C + TSMF / ISDB-T / ISDB-S / 内蔵 B-CAS カードリーダー APDU 対応）
- [`samples/sample_host/`](samples/sample_host): サンプルホスト & 適合性テスト CLI（`mbd-host`）

## ビルドと動作確認

Xcode または Xcode Command Line Tools が必要です。`MBD_SQR100.bundle` のビルドには `libusb` と `pkg-config`（`brew install libusb pkg-config`）が必要です。

```sh
# すべてビルド (MBD_SampleUSB.bundle, MBD_SQR100.bundle, mbd-host)
make

# 仮想サンプルドライバの仕様適合性テスト
make test

# XIT-SQR100 実機接続時の仕様適合性テスト
make test-sqr100

# 各バンドル情報とチャンネル一覧を表示
make info
```

## ライセンス

- 仕様書・SDK ヘッダー・仮想サンプル・ホスト: [MIT License](LICENSE)
- `samples/sqr100_driver/`（`px4_drv` 由来コンポーネントを含む）: GPL-2.0-only
