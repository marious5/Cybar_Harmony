# Cybar_Harmony

[English](README.md) | 简体中文

Cybar_Harmony 是 Cybar 的 HarmonyOS 客户端实现，重点覆盖鸡尾酒配方浏览、推荐、自定义配方创建和社交互动功能。

该仓库包含 Cybar 体验在 HarmonyOS / ArkTS 侧的客户端实现与适配工作。

## 功能特性

- 登录、注册、登出与认证状态处理
- 配方列表，支持分页、刷新、基酒分类筛选、酒精度筛选和排序
- 配方详情页，展示配料、制作说明、图片、描述和酒精度
- 点赞、收藏和评论互动
- 我的收藏、我的创建、我的点赞和用户资料页面
- 自定义配方创建，支持配料选择和酒精度估算
- 图片选择与本地沙箱文件处理
- AI 辅助配方生成流程
- AI 风味分析与评分相关接口集成
- 基于缓存和用户偏好评分的推荐逻辑
- 搜索、设置、深浅色主题和管理后台页面

## 项目结构

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
|   `-- AdminPage.ets
`-- entryability/
    `-- EntryAbility.ets
```

## 技术栈

- HarmonyOS
- ArkTS
- ArkUI
- Stage 模型
- REST API 对接
- 本地缓存
- 文件选择器与沙箱文件操作
- 主题管理

## 主要页面

### 配方列表

配方列表页从后端加载配方数据，以卡片布局展示，并支持基酒和酒精度筛选、排序、下拉刷新和分页加载。

### 配方详情

配方详情页展示完整配方信息，并支持：

- 配料列表
- 制作说明
- 预估酒精度
- 点赞与收藏状态
- 评论列表与评论提交
- AI 风味分析入口

### 自定义配方

自定义配方页支持选择配料、填写制作步骤、计算预估酒精度、选择图片，并接入 AI 辅助生成鸡尾酒配方的流程。

### 用户与管理

应用包含用户侧的资料、收藏、创建配方页面，也包含面向管理场景的用户、配方和评论管理页面。

## 后端接口范围

客户端主要对接以下接口领域：

- Auth：登录、注册、登出、认证状态
- Recipes：配方列表、详情、删除、评分
- Interactions：点赞、收藏、评论
- User：资料、头像、签名、收藏、创建配方、点赞
- Custom recipes：配料、自定义创建、更新、删除、AI 生成
- Recommendations：缓存推荐与评分流程
- Admin：统计、用户、配方、评论

## 开发说明

1. 使用 DevEco Studio 打开项目。
2. 在 API 服务层配置后端 Base URL。
3. 确认后端服务暴露所需的 `/api/...` 路由。
4. 面向 HarmonyOS phone 目标构建运行。

## 项目状态

该项目适合展示一个功能较完整的 HarmonyOS 客户端：配方浏览、社交互动、用户生成内容、AI 辅助创建、推荐、主题和管理工具。

