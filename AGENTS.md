# Agent Instructions

本文件是自动化 agent 的最小约束。规则正文分别归各文档所有，不在此复制；改动前先读对应来源。

- Git Commit 信息使用中文。
- 架构、依赖方向、权益 / 缓存 / 撤销 / 促销签名规则以 [ARCH.md](ARCH.md) 为准。
- 测试分层与运行命令以 [TESTING.md](TESTING.md) 为准；StoreKit 集成细节见 [STOREKIT_TESTING_GUIDE.md](STOREKIT_TESTING_GUIDE.md)。
- 发布、CI、版本与回滚流程以 [DELIVERY.md](DELIVERY.md) 为准。
- 不提交 `.build/`、`.swiftpm/`、`DerivedData/`、`*.xcresult`、`.DS_Store`、凭据或绝对本机路径。
- 公开文档保持机器中立：不描述某一台开发机上安装了什么。
- 不削弱有意义的测试，不引入绕过真实 StoreKit 的镜像实现，不让 `.revoked` 经离线缓存恢复访问，
  不在缺促销签名者时静默退回原价购买。
