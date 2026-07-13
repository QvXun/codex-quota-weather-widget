# 安全说明

请不要在公开 Issue、截图、日志或提交中发送 Token、auth.json、Cookie、真实位置、真实额度、本机路径或任何用户配置。

本副本不应读取认证文件，不应执行网络下载后的内容，不应创建隐藏的管理员任务、系统级持久化或本地监听端口。发现违反这些原则的行为时，请先停止使用公开副本并通过私密渠道报告。

提交前请在本机至少检查：

    git status
    git diff --cached
    rg -n -i 'token|secret|password|authorization|bearer|cookie|C:\\Users\\'

请只使用本地扫描工具；不要为扫描而把源码或配置上传到第三方网站。

当前上游许可证尚未确认，因此该副本暂不建议公开发布。
