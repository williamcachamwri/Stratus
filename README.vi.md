# Stratus

Một ứng dụng quản lý đám mây macOS chuyên nghiệp, được xây dựng bằng Swift 6 + SwiftUI.

[README in English](README.md)

---

## Tính năng

- **Đa nhà cung cấp** — Amazon S3, Google Drive, Dropbox, OneDrive, iCloud Drive, Backblaze B2, Wasabi, Cloudflare R2, Box, SFTP, WebDAV, FTP
- **Tải lên song song theo chunk** — lên đến 32 chunk đồng thời mỗi file, ghép kênh HTTP/2
- **Đồng bộ delta** — so sánh theo block (lấy cảm hứng từ rsync); chỉ tải lên các block đã thay đổi
- **Tiếp tục sau sự cố** — token tiếp tục được lưu trong SQLite, tồn tại sau `kill -9`
- **Kiểm soát tắc nghẽn AIMD** — thuật toán lấy cảm hứng từ TCP, tự động tìm mức song song tối ưu
- **Mã hóa phía client** — AES-256-GCM trước khi tải lên; nhà cung cấp chỉ thấy bản mã
- **Biểu đồ băng thông thời gian thực** — sparkline CoreGraphics 60 giây, làm mượt EWMA
- **Đồng bộ hai chiều** — FSEvents + polling nhà cung cấp, giải quyết xung đột có thể cấu hình
- **Extension File Provider** — tích hợp Finder gốc (tải xuống theo yêu cầu, biểu tượng trạng thái)
- **SHA-256 đầu cuối** — mọi file đều được xác minh; không khớp checksum sẽ thất bại rõ ràng

## Yêu cầu

- macOS 15.0+
- Swift 6.0+

## Xây dựng

```bash
git clone https://github.com/williamcachamwri/Stratus.git
cd Stratus
swift build --product Stratus
```

Đóng gói `.app` unsigned để tự test trên macOS:

```bash
Scripts/build_unsigned_release.sh
open dist/Stratus.app
```

## Kiểm thử

```bash
Scripts/test.sh
```

Hơn 120 unit test và hơn 20 integration test với mock providers.

## Kiến trúc

```
Core/
  Upload/        — Chunk engine, theo dõi băng thông, bộ điều khiển AIMD
  Download/      — Tải xuống song song theo range, lưu trữ tiếp tục
  Providers/     — S3, Google Drive, Dropbox, OneDrive, iCloud, SFTP, WebDAV…
  Sync/          — Đồng bộ hai chiều, giải quyết xung đột, journal FSEvents
  Encryption/    — Pipeline AES-256-GCM, dẫn xuất khóa Argon2id
  VirtualFileSystem/ — Mount FileProvider, cache LRU ngoại tuyến
  Diagnostics/   — Logging có cấu trúc, telemetry, chẩn đoán mạng
  Networking/    — HTTPClient, ghim TLS, proxy, session HTTP/2
  Persistence/   — SQLite GRDB, lưu trữ tài khoản, tùy chọn người dùng
  Auth/          — OAuth2 PKCE, bảo vệ sinh trắc học, kho Keychain

App/
  Features/      — UploadCenter, FileBrowser, SyncManager, MenuBar…
  DesignSystem/  — Màu sắc, Typography, Khoảng cách, Hoạt ảnh
```

## So sánh với CloudMounter

| Tính năng | CloudMounter | Stratus |
|---|---|---|
| Tải lên chunk song song | ✗ | ✓ Lên đến 32 chunk song song |
| Đồng bộ delta | ✗ | ✓ So sánh theo block |
| Chi tiết tiến trình | Chỉ % | Tốc độ, ETA, từng chunk, biểu đồ EWMA |
| Xác minh checksum | ✗ | ✓ SHA-256 mọi file, luôn luôn |
| Kiểm soát tắc nghẽn | ✗ | ✓ AIMD tự động song song |
| Mã hóa phía client | ✗ | ✓ AES-256-GCM, khóa Argon2id |
| Engine đồng bộ | ✗ | ✓ Hai chiều với hàng đợi xung đột |
| Token tiếp tục | ✗ | ✓ SQLite, tồn tại sau sự cố |
| File Provider (không FUSE) | ✗ | ✓ API macOS gốc |
| Xuất chẩn đoán | ✗ | ✓ ZIP: nhật ký, số liệu, theo dõi mạng |

## Giấy phép

MIT — xem [LICENSE](LICENSE).

## Phát triển

Xem [DEVELOP.md](DEVELOP.md) để biết cách setup local, đóng gói unsigned, tạo Sparkle appcast và xử lý lỗi.

## Đóng góp

Xem [CONTRIBUTING.md](CONTRIBUTING.md). Mỗi file thay đổi phải được commit riêng với trailer co-author bắt buộc.
