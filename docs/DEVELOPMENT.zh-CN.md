# Cybar_Harmony 开发说明

[English](DEVELOPMENT.md)

本文档基于当前 HarmonyOS 客户端结构整理，说明项目模块、接口范围和下一步截图/文档任务。

## 仓库范围

Cybar_Harmony 是 Cybar 鸡尾酒应用体验的 HarmonyOS / ArkTS 客户端。该仓库重点在移动端客户端层，而不是后端实现。

根据 `entry/src/main/module.json5`，当前应用面向 HarmonyOS phone 设备。

## 客户端模块

```text
entry/src/main/ets/
|-- common/
|   `-- ThemeManager.ets
|-- models/
|   `-- Recipe.ets
|-- services/
|   `-- APIService.ets
|-- pages/
|   |-- LoginPage.ets
|   |-- RegisterPage.ets
|   |-- RecipesPage.ets
|   |-- RecipeDetailPage.ets
|   |-- CustomRecipePage.ets
|   |-- RecommendationsPage.ets
|   |-- SearchPage.ets
|   |-- MyFavoritesPage.ets
|   |-- MyRecipesPage.ets
|   |-- UserProfilePage.ets
|   |-- SettingsPage.ets
|   |-- EditRecipePage.ets
|   `-- AdminPage.ets
`-- entryability/
    `-- EntryAbility.ets
```

主要页面声明位于 `entry/src/main/resources/base/profile/main_pages.json`。

## 核心接口范围

`entry/src/main/ets/services/APIService.ets` 集中了后端接口交互。当前代码覆盖以下接口领域：

- Auth：状态检查、登录、注册、登出
- Recipes：配方列表、详情、删除、评分
- Recipe interactions：点赞、收藏、评论
- User：收藏、创建配方、点赞、资料、头像、签名
- Custom recipes：配料、自定义创建、更新、删除、AI 生成
- AI analysis：风味分析和评分相关流程
- Admin：统计、用户、配方、评论

## 运行 HarmonyOS 客户端

1. 使用 DevEco Studio 打开仓库。
2. 同步并构建 HarmonyOS 工程。
3. 在 API 服务层配置后端 Base URL。
4. 确认后端暴露所需的 `/api/...` 路由。
5. 在 HarmonyOS phone 目标上运行应用。

## 重点页面

- `RecipesPage.ets`：配方列表、筛选、排序、刷新、分页
- `RecipeDetailPage.ets`：详情、配料、制作说明、互动、评论、AI 分析入口
- `CustomRecipePage.ets`：配料选择、酒精度计算、图片选择、AI 辅助生成
- `RecommendationsPage.ets`：推荐展示和偏好驱动流程
- `UserProfilePage.ets`：用户资料和个人内容入口
- `AdminPage.ets`：面向管理场景的用户、配方和评论管理

## 截图清单

后续补截图时，建议优先覆盖这些页面：

- 登录/注册
- 带筛选的配方列表
- 带配料的配方详情
- 评论、点赞、收藏互动
- 自定义配方创建
- AI 生成配方或 AI 风味分析
- 推荐页面
- 用户资料/收藏页面
- 如需展示管理能力，可补管理页面

推荐存放路径：

```text
docs/assets/
```

建议使用压缩后的 PNG 或 WebP，并在 `README.md` 和 `README.zh-CN.md` 中引用。

## 文档待办

- 为主要 `/api/...` 路由补接口请求和响应示例。
- 后端仓库或服务结构稳定后，补后端部署说明。
- 为中英文 README 增加截图展示区。
- 增加页面 -> 服务层 -> 后端的数据流架构图。

