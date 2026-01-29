## 🚀 安装 (Installation)

复制和执行以下命令：

```bash
wget -N --no-check-certificate "https://raw.githubusercontent.com/SHINYUZ/Quota/main/quota.sh" && chmod +x quota.sh && ./quota.sh
```
如果下载失败，请检查 VPS 的网络连接或 DNS 设置

使用镜像加速源下载：

```bash
wget -N --no-check-certificate https://ghproxy.net/https://raw.githubusercontent.com/SHINYUZ/Quota/main/quota.sh && chmod +x quota.sh && sed -i 's|https://github.com|https://ghproxy.net/https://github.com|g' quota.sh && sed -i 's|https://api.github.com|https://ghproxy.net/https://api.github.com|g' quota.sh && ./quota.sh
```
如果下载失败，请使用其他加速源下载

---

## ⌨️ 快捷指令

安装完成后，以后只需在终端输入以下命令即可打开菜单：

```bash
qo
```

---

## ⚠️ 免责声明

1. 本脚本仅供学习交流使用，请勿用于非法用途。
2. 使用本脚本造成的任何损失（包括但不限于数据丢失、服务器被封锁等），作者不承担任何责任。
3. 请遵守当地法律法规。

---

## 📄 开源协议

本项目遵循 [GPL-3.0 License](LICENSE) 协议开源。

Copyright (c) 2026 Shinyuz

---

**如果这个脚本对你有帮助，请给一个 ⭐ Star！**
