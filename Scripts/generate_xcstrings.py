#!/usr/bin/env python3
"""Generate Localizable.xcstrings with all 8 target languages."""

import json, os

TARGET_LANGUAGES = ["en", "vi", "fr", "de", "es", "ja", "zh-Hans", "ko", "pt-BR"]

# English key → { vi: "translation" }
# Other 7 languages get "needs review" state with English as placeholder
strings = {
    # === Navigation Titles ===
    "Accounts": {"vi": "Tài khoản", "comment": "Navigation title for accounts list"},
    "Choose Provider": {"vi": "Chọn nhà cung cấp", "comment": "Navigation title fallback"},
    "Upload Center": {"vi": "Trung tâm tải lên", "comment": "Primary transfer dashboard title"},
    "Download Center": {"vi": "Trung tâm tải xuống", "comment": "Downloads dashboard"},
    "Sync Manager": {"vi": "Quản lý đồng bộ", "comment": "Sync management view"},
    "Files": {"vi": "Tập tin", "comment": "File browser title"},
    "New Sync Pair": {"vi": "Cặp đồng bộ mới", "comment": "Sheet title for creating a sync pair"},
    "Transfers": {"vi": "Truyền tải", "comment": "Transfer preferences title"},
    "Create Encrypted Vault": {"vi": "Tạo kho mã hóa", "comment": "Vault creation wizard title"},
    "Stratus": {"vi": "Stratus", "comment": "App name"},

    # === Tab / Sidebar ===
    "Library": {"vi": "Thư viện", "comment": "Sidebar section"},
    "Uploads": {"vi": "Đang tải lên", "comment": "Tab label"},
    "Downloads": {"vi": "Đang tải xuống", "comment": "Tab label"},
    "Sync": {"vi": "Đồng bộ", "comment": "Tab label / command menu"},
    "Mounts": {"vi": "Ổ đĩa", "comment": "Tab label for Finder mounts"},
    "Preferences": {"vi": "Cài đặt", "comment": "Tab label"},
    "Add account…": {"vi": "Thêm tài khoản…", "comment": "Empty state label in sidebar"},
    "Finder": {"vi": "Finder", "comment": "Sidebar section"},
    "Open Mount Manager": {"vi": "Mở quản lý ổ đĩa", "comment": "Sidebar action row"},
    "Sync Pairs": {"vi": "Cặp đồng bộ", "comment": "Sidebar section"},
    "No sync pairs": {"vi": "Không có cặp đồng bộ", "comment": "Empty state label"},
    "General": {"vi": "Chung", "comment": "Preferences tab"},
    "Bandwidth": {"vi": "Băng thông", "comment": "Preferences tab"},
    "Encryption": {"vi": "Mã hóa", "comment": "Preferences tab"},
    "Notifications": {"vi": "Thông báo", "comment": "Preferences tab"},
    "Inspector": {"vi": "Thanh tra", "comment": "Inspector panel"},

    # === Empty State Titles ===
    "No Cloud Accounts": {"vi": "Chưa có tài khoản đám mây", "comment": "Empty state title"},
    "No Sync Pairs": {"vi": "Chưa có cặp đồng bộ", "comment": "Empty state title"},
    "No download activity": {"vi": "Không có hoạt động tải xuống", "comment": "Empty state title"},
    "No upload activity": {"vi": "Không có hoạt động tải lên", "comment": "Empty state title"},
    "Load Failed": {"vi": "Tải thất bại", "comment": "Error state title"},
    "Empty Folder": {"vi": "Thư mục trống", "comment": "Empty folder title"},
    "No Provider Definitions": {"vi": "Không có định nghĩa nhà cung cấp", "comment": "Error state"},
    "No accounts to mount": {"vi": "Không có tài khoản để gắn", "comment": "Empty state"},
    "No mounted accounts": {"vi": "Chưa có ổ đĩa nào được gắn", "comment": "Empty state"},

    # === Empty State Subtitles ===
    "Add a real account to start browsing, mounting, uploading, and syncing.": {
        "vi": "Thêm tài khoản thực để bắt đầu duyệt, gắn ổ đĩa, tải lên và đồng bộ.",
        "comment": "Empty state subtitle"
    },
    "Create a sync pair to keep a local folder in sync with your cloud storage.": {
        "vi": "Tạo cặp đồng bộ để giữ thư mục cục bộ đồng bộ với lưu trữ đám mây.",
        "comment": "Empty state subtitle"
    },
    "Start an upload from the file browser. Every file will show bytes, speed, chunk progress, checksum status, and retry state here.": {
        "vi": "Bắt đầu tải lên từ trình duyệt tập tin. Mọi tập tin sẽ hiển thị dung lượng, tốc độ, tiến trình, trạng thái kiểm tra và thử lại tại đây.",
        "comment": "Upload center empty subtitle"
    },
    "Select an account to browse files.": {
        "vi": "Chọn tài khoản để duyệt tập tin.",
        "comment": "Empty state subtitle"
    },
    "Drop files here to upload them.": {
        "vi": "Thả tập tin vào đây để tải lên.",
        "comment": "Empty state subtitle for drag-drop"
    },
    "Add a provider account first, then Stratus can expose it in Finder Locations.": {
        "vi": "Thêm tài khoản nhà cung cấp trước, sau đó Stratus có thể hiển thị nó trong Finder.",
        "comment": "Mount empty state"
    },
    "Choose Mount Account to register a File Provider domain in Finder.": {
        "vi": "Chọn tài khoản để đăng ký miền File Provider trong Finder.",
        "comment": "Mount empty state action hint"
    },

    # === Buttons / Actions ===
    "Add Account": {"vi": "Thêm tài khoản", "comment": "Button to add account"},
    "Remove": {"vi": "Xóa", "comment": "Swipe action"},
    "Cancel": {"vi": "Hủy", "comment": "Cancel button"},
    "Back": {"vi": "Quay lại", "comment": "Go back button"},
    "Add": {"vi": "Thêm", "comment": "Confirm add button"},
    "Authorizing…": {"vi": "Đang xác thực…", "comment": "OAuth button state"},
    "Authorize in Browser": {"vi": "Xác thực qua trình duyệt", "comment": "OAuth action button"},
    "Pause All": {"vi": "Tạm dừng tất cả", "comment": "Button to pause all transfers"},
    "Resume All": {"vi": "Tiếp tục tất cả", "comment": "Button to resume transfers"},
    "Cancel All": {"vi": "Hủy tất cả", "comment": "Cancel all transfers"},
    "Pause": {"vi": "Tạm dừng", "comment": "Per-row pause"},
    "Resume": {"vi": "Tiếp tục", "comment": "Per-row resume"},
    "Retry All Failed": {"vi": "Thử lại tất cả lỗi", "comment": "Button that retries failed transfer tasks."},
    "Retry": {"vi": "Thử lại", "comment": "Retry action / notification action"},
    "Prioritize": {"vi": "Ưu tiên", "comment": "Move to top of queue"},
    "Sync All Now": {"vi": "Đồng bộ tất cả ngay", "comment": "Manual sync trigger"},
    "Open Stratus": {"vi": "Mở Stratus", "comment": "Menu bar action / notification action"},
    "Quit": {"vi": "Thoát", "comment": "Quit app"},
    "Add Sync Pair": {"vi": "Thêm cặp đồng bộ", "comment": "Empty state action button"},
    "Add Pair": {"vi": "Thêm cặp", "comment": "Toolbar action"},
    "Sync All": {"vi": "Đồng bộ tất cả", "comment": "Toolbar action"},
    "About Stratus": {"vi": "Giới thiệu Stratus", "comment": "App menu / panel title"},
    "Check for Updates…": {"vi": "Kiểm tra cập nhật…", "comment": "App menu"},
    "Copy Google Drive Link": {"vi": "Sao chép liên kết Google Drive", "comment": "Context menu"},
    "Mount Account": {"vi": "Gắn tài khoản", "comment": "Mount action"},
    "Unmount": {"vi": "Tháo ổ đĩa", "comment": "Unmount action"},
    "Reset Defaults": {"vi": "Khôi phục mặc định", "comment": "Reset button"},
    "Create Vault": {"vi": "Tạo kho", "comment": "Button to create vault"},
    "Acknowledgements": {"vi": "Ghi nhận", "comment": "About panel button"},
    "Close": {"vi": "Đóng", "comment": "Close button"},

    # === Inspector ===
    "Selection": {"vi": "Lựa chọn", "comment": "Inspector group"},
    "View": {"vi": "Xem", "comment": "Inspector row label"},
    "Status": {"vi": "Trạng thái", "comment": "Inspector row label"},
    "Transferring": {"vi": "Đang truyền", "comment": "Status value"},
    "Idle": {"vi": "Không hoạt động", "comment": "Status value"},
    "Upload Session": {"vi": "Phiên tải lên", "comment": "Inspector group"},
    "Progress": {"vi": "Tiến trình", "comment": "Inspector row label"},
    "Transferred": {"vi": "Đã truyền", "comment": "Inspector row label"},
    "Total": {"vi": "Tổng cộng", "comment": "Inspector row label"},
    "Current": {"vi": "Hiện tại", "comment": "StatCell label"},
    "Peak": {"vi": "Cao nhất", "comment": "StatCell label"},
    "ETA": {"vi": "Thời gian còn lại", "comment": "Estimated time remaining"},
    "Files": {"vi": "Tập tin", "comment": "File count label"},
    "Uploading": {"vi": "Đang tải lên", "comment": "Status label"},
    "Downloading": {"vi": "Đang tải xuống", "comment": "Status label"},
    "Queued": {"vi": "Đang chờ", "comment": "Section title / status"},
    "Paused": {"vi": "Đã tạm dừng", "comment": "Section title / status"},
    "Failed": {"vi": "Thất bại", "comment": "Section title / status"},
    "Completed": {"vi": "Hoàn thành", "comment": "Section title / status"},
    "In Progress": {"vi": "Đang tiến hành", "comment": "Section title"},

    # === Status Bar ===
    "Online": {"vi": "Trực tuyến", "comment": "Connection status"},
    "Offline": {"vi": "Ngoại tuyến", "comment": "Connection status"},
    "Ready": {"vi": "Sẵn sàng", "comment": "Account health status"},
    "Needs attention": {"vi": "Cần chú ý", "comment": "Account health status"},

    # === MenuBar ===
    "No accounts": {"vi": "Không có tài khoản", "comment": "Menu bar empty state"},
    "Stratus – Cloud Drive Manager": {"vi": "Stratus – Trình quản lý ổ đám mây", "comment": "Menu bar tooltip"},

    # === Upload Phase Labels ===
    "Preparing": {"vi": "Đang chuẩn bị", "comment": "Upload phase: hashing"},
    "Verified": {"vi": "Đã xác minh", "comment": "Phase: checksum verified"},
    "Done": {"vi": "Hoàn tất", "comment": "Phase: completed"},
    "Cancelled": {"vi": "Đã hủy", "comment": "Phase: cancelled"},
    "Skipped": {"vi": "Đã bỏ qua", "comment": "Phase: skipped"},

    # === Form Section Headers ===
    "Account": {"vi": "Tài khoản", "comment": "Form section / picker label"},
    "Provider": {"vi": "Nhà cung cấp", "comment": "Provider label"},
    "S3 Endpoint": {"vi": "Điểm đầu cuối S3", "comment": "Section header"},
    "Bucket": {"vi": "Bucket", "comment": "Field label"},
    "Region": {"vi": "Khu vực", "comment": "Field label"},
    "Custom endpoint URL": {"vi": "URL điểm đầu cuối tùy chỉnh", "comment": "Field placeholder"},
    "Path-style URLs": {"vi": "URL kiểu đường dẫn", "comment": "Toggle label"},
    "Transfer acceleration": {"vi": "Tăng tốc truyền tải", "comment": "Toggle label"},
    "Credentials": {"vi": "Thông tin xác thực", "comment": "Section header"},
    "Access key ID": {"vi": "ID khóa truy cập", "comment": "Field placeholder"},
    "Secret access key": {"vi": "Khóa truy cập bí mật", "comment": "Secure field"},
    "Session token (optional)": {"vi": "Token phiên (không bắt buộc)", "comment": "Secure field"},
    "SFTP Server": {"vi": "Máy chủ SFTP", "comment": "Section header"},
    "Host": {"vi": "Máy chủ", "comment": "Field label"},
    "Port": {"vi": "Cổng", "comment": "Field label"},
    "Username": {"vi": "Tên người dùng", "comment": "Field label"},
    "Password": {"vi": "Mật khẩu", "comment": "Field label"},
    "WebDAV Server": {"vi": "Máy chủ WebDAV", "comment": "Section header"},
    "Base URL": {"vi": "URL gốc", "comment": "Field placeholder"},
    "FTP / FTPS Server": {"vi": "Máy chủ FTP / FTPS", "comment": "Section header"},
    "Base path": {"vi": "Đường dẫn gốc", "comment": "Field placeholder"},
    "Use implicit FTPS": {"vi": "Sử dụng FTPS ngầm", "comment": "Toggle label"},
    "OAuth": {"vi": "OAuth", "comment": "Section header"},
    "Client ID": {"vi": "ID máy khách", "comment": "Field placeholder"},
    "Redirect URI": {"vi": "URI chuyển hướng", "comment": "Field placeholder"},
    "Scopes": {"vi": "Phạm vi", "comment": "Field placeholder"},
    "Error": {"vi": "Lỗi", "comment": "Section header / status"},
    "Display name": {"vi": "Tên hiển thị", "comment": "Field placeholder"},
    "Email or label": {"vi": "Email hoặc nhãn", "comment": "Field placeholder"},
    "OAuth token received and ready to save": {"vi": "Đã nhận token OAuth và sẵn sàng lưu", "comment": "Confirmation label"},

    # === Preferences ===
    "Launch at login": {"vi": "Khởi chạy khi đăng nhập", "comment": "Toggle"},
    "Show Dock icon": {"vi": "Hiển thị biểu tượng Dock", "comment": "Toggle"},
    "Update channel": {"vi": "Kênh cập nhật", "comment": "Picker label"},
    "Stable": {"vi": "Ổn định", "comment": "Picker option"},
    "Beta": {"vi": "Thử nghiệm", "comment": "Picker option"},
    "Upload limit:": {"vi": "Giới hạn tải lên:", "comment": "Bandwidth limit label"},
    "Download limit:": {"vi": "Giới hạn tải xuống:", "comment": "Bandwidth limit label"},
    "Schedule": {"vi": "Lịch trình", "comment": "Section header"},
    "Bandwidth scheduling available per sync pair": {"vi": "Lập lịch băng thông khả dụng theo từng cặp đồng bộ", "comment": "Caption"},
    "Enable client-side encryption": {"vi": "Bật mã hóa phía máy khách", "comment": "Toggle"},
    "Master password": {"vi": "Mật khẩu chính", "comment": "SecureField placeholder"},
    "Confirm password": {"vi": "Xác nhận mật khẩu", "comment": "SecureField placeholder"},
    "Saving…": {"vi": "Đang lưu…", "comment": "Button saving state"},
    "Update Master Password": {"vi": "Cập nhật mật khẩu chính", "comment": "Button"},
    "Set Master Password": {"vi": "Đặt mật khẩu chính", "comment": "Button"},
    "Upload completed": {"vi": "Tải lên hoàn tất", "comment": "Notification toggle"},
    "Upload failed": {"vi": "Tải lên thất bại", "comment": "Notification toggle"},
    "Sync conflict detected": {"vi": "Phát hiện xung đột đồng bộ", "comment": "Notification toggle"},
    "Master password saved.": {"vi": "Đã lưu mật khẩu chính.", "comment": "Success feedback"},

    # === Sync Form ===
    "Local Folder": {"vi": "Thư mục cục bộ", "comment": "Field placeholder"},
    "Remote Path": {"vi": "Đường dẫn từ xa", "comment": "Field placeholder"},
    "Sync Mode": {"vi": "Chế độ đồng bộ", "comment": "Picker label"},
    "Conflicts": {"vi": "Xung đột", "comment": "Section header"},
    "Active Sync Pairs": {"vi": "Cặp đồng bộ đang hoạt động", "comment": "Section header"},

    # === About Panel ===
    "Native macOS Cloud Drive Manager": {"vi": "Trình quản lý ổ đám mây macOS gốc", "comment": "App subtitle"},
    "Version": {"vi": "Phiên bản", "comment": "Info label"},
    "Bundle ID": {"vi": "Bundle ID", "comment": "Info label"},
    "Runtime": {"vi": "Thời gian chạy", "comment": "Info label"},
    "Updates": {"vi": "Cập nhật", "comment": "Info label"},
    "Unsigned open-source build": {"vi": "Bản dựng mã nguồn mở chưa ký", "comment": "Info value"},
    "Sparkle direct release channel": {"vi": "Kênh phát hành trực tiếp Sparkle", "comment": "Info value"},
    "Every file, every time, as fast as your internet allows.": {
        "vi": "Mọi tập tin, mọi lúc, nhanh nhất có thể.",
        "comment": "Primary Stratus promise shown in onboarding and marketing surfaces."
    },

    # === Strings already in original xcstrings ===
    "Pause All": {"vi": "Tạm dừng tất cả", "comment": "Button that pauses all active transfers."},
    "Resume All": {"vi": "Tiếp tục tất cả", "comment": "Button that resumes paused transfers."},
    "Retry All Failed": {"vi": "Thử lại tất cả lỗi", "comment": "Button that retries failed transfer tasks."},
    "Upload Center": {"vi": "Trung tâm tải lên", "comment": "Primary transfer dashboard title."},

    # === Provider Picker ===
    "Connect a Cloud Account": {"vi": "Kết nối tài khoản đám mây", "comment": "Header text"},
    "Parallel": {"vi": "Song song", "comment": "Capability pill"},
    "Sequential": {"vi": "Tuần tự", "comment": "Capability pill"},

    # === Mount Manager ===
    "Mount Manager": {"vi": "Quản lý ổ đĩa", "comment": "Title"},
    "Mounted": {"vi": "Đã gắn", "comment": "Status value"},
    "Syncing": {"vi": "Đang đồng bộ", "comment": "Status value"},
    "All accounts are mounted": {"vi": "Tất cả tài khoản đã được gắn", "comment": "Empty state menu text"},
    "Provider:": {"vi": "Nhà cung cấp:", "comment": "Label prefix"},
    "Quota:": {"vi": "Hạn ngạch:", "comment": "Label prefix"},
    "Cache:": {"vi": "Bộ nhớ đệm:", "comment": "Label prefix"},
    "Unlimited": {"vi": "Không giới hạn", "comment": "Unlimited quota/bandwidth"},

    # === Sync Rule Editor ===
    "Sync Rules": {"vi": "Quy tắc đồng bộ", "comment": "Header text"},
    "Type": {"vi": "Loại", "comment": "Picker label"},
    "Include": {"vi": "Bao gồm", "comment": "Picker option"},
    "Exclude": {"vi": "Loại trừ", "comment": "Picker option"},
    "Scope": {"vi": "Phạm vi", "comment": "Picker label"},
    "Name": {"vi": "Tên", "comment": "Picker option / rule by name"},
    "Path": {"vi": "Đường dẫn", "comment": "Picker option / rule by path"},
    "Extension": {"vi": "Phần mở rộng", "comment": "Picker option / rule by extension"},

    # === Transfer Preferences ===
    "Parallelism": {"vi": "Song song hóa", "comment": "Section header"},
    "Concurrent files:": {"vi": "Tập tin đồng thời:", "comment": "Stepper label"},
    "Global chunk slots:": {"vi": "Khe chunk toàn cục:", "comment": "Stepper label"},
    "Network Policy": {"vi": "Chính sách mạng", "comment": "Section header"},
    "Allow expensive networks": {"vi": "Cho phép mạng đắt tiền", "comment": "Toggle"},
    "Allow constrained networks": {"vi": "Cho phép mạng hạn chế", "comment": "Toggle"},

    # === Vault ===
    "Vault Format": {"vi": "Định dạng kho", "comment": "Section header"},
    "Format": {"vi": "Định dạng", "comment": "Picker label"},
    "Stratus Native": {"vi": "Stratus gốc", "comment": "Vault mode"},
    "Cryptomator": {"vi": "Cryptomator", "comment": "Vault mode"},
    "Encryption Key": {"vi": "Khóa mã hóa", "comment": "Section header"},
    "Vault password": {"vi": "Mật khẩu kho", "comment": "SecureField"},
    "Allow Touch ID / Apple Watch unlock": {"vi": "Cho phép mở khóa bằng Touch ID / Apple Watch", "comment": "Toggle"},
    "Pipeline": {"vi": "Đường ống", "comment": "Section header"},
    "Read chunk": {"vi": "Đọc chunk", "comment": "Pipeline stage"},
    "Hash plaintext": {"vi": "Băm văn bản gốc", "comment": "Pipeline stage"},
    "Encrypt AES-GCM": {"vi": "Mã hóa AES-GCM", "comment": "Pipeline stage"},
    "Upload ciphertext": {"vi": "Tải lên bản mã", "comment": "Pipeline stage"},
    "Verify encrypted checksum": {"vi": "Xác minh checksum mã hóa", "comment": "Pipeline stage"},

    # === Drag & Drop ===
    "Drop to upload": {"vi": "Thả để tải lên", "comment": "Drag overlay label"},
    "Copied Google Drive link": {"vi": "Đã sao chép liên kết Google Drive", "comment": "Feedback toast"},
    "Queued for upload": {"vi": "Đã xếp hàng để tải lên", "comment": "Feedback prefix"},
    "Upload failed:": {"vi": "Tải lên thất bại:", "comment": "Error prefix"},
    "Unsupported drop item type": {"vi": "Loại mục thả không được hỗ trợ", "comment": "Error feedback"},
    "Error:": {"vi": "Lỗi:", "comment": "Error prefix"},

    # === Notifications ===
    "Upload Complete": {"vi": "Tải lên hoàn tất", "comment": "Notification title"},
    "Upload Failed": {"vi": "Tải lên thất bại", "comment": "Notification title"},
    "Sync Conflict": {"vi": "Xung đột đồng bộ", "comment": "Notification title"},
    "Sync Complete —": {"vi": "Đồng bộ hoàn tất —", "comment": "Notification title prefix"},
    "uploaded": {"vi": "đã tải lên", "comment": "Notification body part"},
    "downloaded": {"vi": "đã tải xuống", "comment": "Notification body part"},
    "Resolve": {"vi": "Giải quyết", "comment": "Notification action"},

    # === Accessibility ===
    "Double-tap to view upload details": {"vi": "Nhấn đúp để xem chi tiết tải lên", "comment": "Accessibility hint"},
    "Upload speed graph": {"vi": "Biểu đồ tốc độ tải lên", "comment": "Accessibility label"},
    "Overall upload progress": {"vi": "Tiến trình tải lên tổng thể", "comment": "Accessibility label"},
    "Overall download progress": {"vi": "Tiến trình tải xuống tổng thể", "comment": "Accessibility label"},
    "Upload queue": {"vi": "Hàng đợi tải lên", "comment": "Accessibility label"},
    "Cloud path": {"vi": "Đường dẫn đám mây", "comment": "Accessibility label"},
    "percent": {"vi": "phần trăm", "comment": "Accessibility value"},

    # === Cloud Path Bar ===
    "Root": {"vi": "Gốc", "comment": "Root path component"},
    "Finder Locations": {"vi": "Vị trí Finder", "comment": "Default mount path"},

    # === Provider Names (Accessibility / UI) ===
    "Amazon S3": {"vi": "Amazon S3", "comment": "Provider name"},
    "Wasabi": {"vi": "Wasabi", "comment": "Provider name"},
    "Backblaze B2": {"vi": "Backblaze B2", "comment": "Provider name"},
    "Cloudflare R2": {"vi": "Cloudflare R2", "comment": "Provider name"},
    "Google Drive": {"vi": "Google Drive", "comment": "Provider name"},
    "Dropbox": {"vi": "Dropbox", "comment": "Provider name"},
    "OneDrive": {"vi": "OneDrive", "comment": "Provider name"},
    "Box": {"vi": "Box", "comment": "Provider name"},
    "iCloud Drive": {"vi": "iCloud Drive", "comment": "Provider name"},
    "SFTP": {"vi": "SFTP", "comment": "Provider name"},
    "WebDAV": {"vi": "WebDAV", "comment": "Provider name"},
    "FTP / FTPS": {"vi": "FTP / FTPS", "comment": "Provider name"},
    "Cloud provider": {"vi": "Nhà cung cấp đám mây", "comment": "Fallback"},

    # === Capabilities ===
    "parallel chunks": {"vi": "chunk song song", "comment": "Capability text"},
    "resume": {"vi": "tiếp tục", "comment": "Capability text"},
    "transfer acceleration": {"vi": "tăng tốc truyền tải", "comment": "Capability text"},

    # === Detail / Status Text ===
    "live transfer": {"vi": "truyền trực tiếp", "comment": "Live transfer detail"},
    "Queued at scheduler priority": {"vi": "Đã xếp hàng ở ưu tiên", "comment": "Upload detail prefix"},
    "Preparing checksum, delta check, and upload session": {"vi": "Đang chuẩn bị checksum, kiểm tra delta và phiên tải lên", "comment": "Upload detail"},
    "SHA-256 verified": {"vi": "SHA-256 đã xác minh", "comment": "Checksum detail"},
    "Uploaded; checksum unavailable": {"vi": "Đã tải lên; không có checksum", "comment": "Checksum detail"},
    "Paused with resume state preserved": {"vi": "Đã tạm dừng, trạng thái được lưu", "comment": "Pause detail"},
    "Queued for resume": {"vi": "Đã xếp hàng để tiếp tục", "comment": "Resume detail"},
    "Cancelled by user": {"vi": "Đã hủy bởi người dùng", "comment": "Cancel detail"},
    "chunks": {"vi": "chunk", "comment": "Chunk summary"},
    "retries": {"vi": "lần thử lại", "comment": "Chunk summary suffix"},
    "in flight": {"vi": "đang truyền", "comment": "Chunk progress suffix"},
    "failed chunks": {"vi": "chunk thất bại", "comment": "Failed chunks text"},
    "ranges": {"vi": "phạm vi", "comment": "Range summary"},
    "Checksum verified": {"vi": "Checksum đã xác minh", "comment": "Download checksum"},
    "Downloaded; checksum unavailable": {"vi": "Đã tải xuống; không có checksum", "comment": "Download checksum"},
    "Waiting for byte-range slots": {"vi": "Đang chờ khe byte-range", "comment": "Download pending detail"},
    "Waiting for metadata": {"vi": "Đang chờ siêu dữ liệu", "comment": "Download pending detail"},
    "Chunk": {"vi": "Chunk", "comment": "Chunk progress prefix"},
    "Segment": {"vi": "Đoạn", "comment": "Range progress prefix"},
    "No provider is registered for": {"vi": "Không có nhà cung cấp nào được đăng ký cho", "comment": "Provider error prefix"},
    "Check account configuration.": {"vi": "Kiểm tra cấu hình tài khoản.", "comment": "Provider error suffix"},
    "active": {"vi": "đang hoạt động", "comment": "Status text"},
    "queued": {"vi": "đang chờ", "comment": "Status text"},
    "failed": {"vi": "thất bại", "comment": "Status text"},
    "files remaining": {"vi": "tập tin còn lại", "comment": "Status bar text"},
    "Pattern, e.g. *.tmp": {"vi": "Mẫu, ví dụ *.tmp", "comment": "TextField placeholder"},

    # === Captions / Detail Text ===
    "0 means unlimited. Limits are enforced by scheduler delays between chunk uploads.": {
        "vi": "0 có nghĩa là không giới hạn. Giới hạn được thực thi bởi độ trễ lập lịch giữa các lần tải chunk.",
        "comment": "Transfer prefs caption"
    },
    "The scheduler still respects provider caps and congestion feedback.": {
        "vi": "Bộ lập lịch vẫn tôn trọng giới hạn nhà cung cấp và phản hồi tắc nghẽn.",
        "comment": "Transfer prefs caption"
    },
    "AES-256-GCM per chunk with encrypted manifest metadata.": {
        "vi": "AES-256-GCM theo từng chunk với siêu dữ liệu kê khai được mã hóa.",
        "comment": "Vault mode detail"
    },
    "Interoperable vault layout for users who need external readers.": {
        "vi": "Bố cục kho tương thích cho người dùng cần trình đọc bên ngoài.",
        "comment": "Vault mode detail"
    },
    "Files are encrypted with AES-256-GCM before upload. Your password never leaves this device.": {
        "vi": "Tập tin được mã hóa bằng AES-256-GCM trước khi tải lên. Mật khẩu của bạn không bao giờ rời khỏi thiết bị này.",
        "comment": "Encryption caption"
    },
    "Defaults load from shared/oauth.config, shared/*.local.config, or matching environment variables.": {
        "vi": "Giá trị mặc định được tải từ shared/oauth.config, shared/*.local.config hoặc biến môi trường phù hợp.",
        "comment": "OAuth config caption"
    },
    "This provider is configured by macOS or the File Provider extension. No demo account will be created; only a persisted account row is saved.": {
        "vi": "Nhà cung cấp này được cấu hình bởi macOS hoặc tiện ích mở rộng File Provider. Không có tài khoản demo nào được tạo; chỉ lưu một dòng tài khoản.",
        "comment": "System provider caption"
    },
    "Providers are loaded from ProviderDefinitions.json so the onboarding UI matches the real backend capabilities.": {
        "vi": "Các nhà cung cấp được tải từ ProviderDefinitions.json để giao diện người dùng khớp với khả năng thực tế của backend.",
        "comment": "Provider picker caption"
    },
    "Move this queued upload to critical priority.": {
        "vi": "Di chuyển mục tải lên đang chờ này lên ưu tiên cao nhất.",
        "comment": "Tooltip"
    },
    "Real download events from DownloadEngine will appear here with bytes, range segments, speed, ETA, and resume state.": {
        "vi": "Sự kiện tải xuống thực tế từ DownloadEngine sẽ xuất hiện tại đây với dung lượng, phân đoạn, tốc độ, thời gian còn lại và trạng thái tiếp tục.",
        "comment": "Download center empty subtitle"
    },
    "ProviderDefinitions.json was not found in the app bundle or repository Resources folder.": {
        "vi": "Không tìm thấy ProviderDefinitions.json trong bundle ứng dụng hoặc thư mục Resources.",
        "comment": "Provider definitions error"
    },
    "Finder Locations volumes backed by File Provider and offline cache.": {
        "vi": "Ổ đĩa Finder Locations được hỗ trợ bởi File Provider và bộ nhớ đệm ngoại tuyến.",
        "comment": "Mount manager subtitle"
    },
    "was modified both locally and remotely": {
        "vi": "đã được sửa đổi cả cục bộ và từ xa",
        "comment": "Notification body for conflict"
    },
    "Transfer only": {
        "vi": "Chỉ truyền tải",
        "comment": "Capability pill for providers without Finder support"
    },
    "download progress": {
        "vi": "tiến trình tải xuống",
        "comment": "Accessibility label for download rows"
    },
}

# Build the xcstrings JSON structure
result = {
    "sourceLanguage": "en",
    "strings": {},
    "version": "1.0"
}

for key, data in strings.items():
    entry = {
        "comment": data.get("comment", ""),
        "extractionState": "manual",
        "localizations": {}
    }

    for lang in TARGET_LANGUAGES:
        if lang == "en":
            entry["localizations"]["en"] = {
                "stringUnit": {
                    "state": "translated",
                    "value": key
                }
            }
        elif lang == "vi":
            entry["localizations"]["vi"] = {
                "stringUnit": {
                    "state": "translated",
                    "value": data["vi"]
                }
            }
        else:
            # Placeholder for other languages — marked "needs review"
            entry["localizations"][lang] = {
                "stringUnit": {
                    "state": "needs review",
                    "value": key
                }
            }

    result["strings"][key] = entry

output_path = os.path.join(os.path.dirname(os.path.dirname(__file__)),
                           "Resources", "Localizable.xcstrings")
with open(output_path, "w", encoding="utf-8") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

print(f"Generated {output_path}")
print(f"Total strings: {len(strings)}")
print(f"Languages: {', '.join(TARGET_LANGUAGES)}")
print(f"Vietnamese: translated ✓")
print(f"fr, de, es, ja, zh-Hans, ko, pt-BR: needs review")
