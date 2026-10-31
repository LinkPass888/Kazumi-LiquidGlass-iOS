# Cline Global Rules for Kazumi Native Migration
1. 严禁盲写或捏造任何 API 接口、加密算法和解析逻辑！在创建任何 Swift 业务代码前，必须先用 `read_file` 工具读取 `lib/` 目录下对应的 `.dart` 源文件。
2. 严禁修改 `ios/Runner/Assets.xcassets` 下的任何图标资源，必须 100% 保持原项目的 `PRODUCT_BUNDLE_IDENTIFIER` 包名不变。
3. 严禁在代码中使用 `// TODO`、`// 省略实现` 等占位符，所有生成的文件必须是完整可编译的 Swift 6 + SwiftUI 代码。
4. 由于当前在 Windows 环境下开发，不要直接手写或修改 `.xcodeproj/project.pbxproj`，统一通过维护 `ios/project.yml` (XcodeGen) 来管理原生工程依赖与源码路径。
