# Cybar_Harmony Development Guide

[简体中文](DEVELOPMENT.zh-CN.md)

This guide summarizes the current HarmonyOS client structure, API areas, and the next documentation/screenshot tasks.

## Repository Scope

Cybar_Harmony is a HarmonyOS / ArkTS client for the Cybar cocktail experience. The repository is focused on the mobile client layer rather than the backend implementation.

The app currently targets HarmonyOS phone devices according to `entry/src/main/module.json5`.

## Client Modules

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

Main pages are declared in `entry/src/main/resources/base/profile/main_pages.json`.

## Core API Areas

`entry/src/main/ets/services/APIService.ets` centralizes backend interaction. The current code integrates with these API groups:

- Auth: status, login, register, logout
- Recipes: list, detail, delete, ratings
- Recipe interactions: like, favorite, comments
- User: favorites, created recipes, likes, profile, avatar, signature
- Custom recipes: ingredients, create, update, delete, AI generation
- AI analysis: flavor analysis and rating-related flows
- Admin: stats, users, recipes, comments

## Run the HarmonyOS Client

1. Open the repository in DevEco Studio.
2. Sync/build the HarmonyOS project.
3. Configure the backend base URL in the API service layer.
4. Make sure the backend exposes the required `/api/...` routes.
5. Run the app on a HarmonyOS phone target.

## Important Pages

- `RecipesPage.ets`: recipe list, filtering, sorting, refresh, paging
- `RecipeDetailPage.ets`: detail, ingredients, instructions, interactions, comments, AI analysis entry
- `CustomRecipePage.ets`: ingredient selection, ABV calculation, image selection, AI-assisted generation
- `RecommendationsPage.ets`: recommendation display and preference-driven flows
- `UserProfilePage.ets`: user profile and personal content entry points
- `AdminPage.ets`: admin-facing users, recipes, and comments management

## Screenshot Checklist

When screenshots are ready, prioritize these views:

- Login/register
- Recipe list with filters
- Recipe detail with ingredients
- Comments and like/favorite interaction
- Custom recipe creation
- AI-generated recipe or AI flavor analysis
- Recommendations page
- User profile / favorites
- Admin page if you want to show management features

Recommended storage path:

```text
docs/assets/
```

Use compressed PNG or WebP files and reference them from `README.md` and `README.zh-CN.md`.

## Documentation Backlog

- Add API contract examples for the main `/api/...` routes.
- Add backend deployment notes once the backend repository or service layout is finalized.
- Add screenshot sections to both README versions.
- Add a short architecture diagram for page -> service -> backend data flow.

