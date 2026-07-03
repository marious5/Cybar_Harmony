# Cybar_Harmony

English | [简体中文](README.zh-CN.md)

A HarmonyOS client for Cybar, focused on cocktail recipes, recommendations, custom recipe creation, and social interaction features.

This repository contains the HarmonyOS/ArkTS client implementation and adaptation work for the Cybar experience.

## Features

- Login, register, logout, and auth status handling
- Recipe list with paging, refresh, category filtering, ABV filtering, and sorting
- Recipe detail page with ingredients, instructions, image, description, and ABV display
- Like, favorite, and comment interactions
- Favorites, created recipes, liked recipes, and user profile pages
- Custom recipe creation with ingredient selection and ABV calculation
- Image picking and local sandbox file handling for custom recipes
- AI-assisted recipe generation flow
- AI flavor analysis and rating-related API integration
- Recommendation logic with caching and user preference scoring
- Search, settings, dark/light theme support, and admin pages

## Project Structure

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

## Tech Stack

- HarmonyOS
- ArkTS
- ArkUI
- Stage model
- REST API integration
- Local cache
- File picker and sandbox file operations
- Theme management

## Main Pages

### Recipes

The recipe list page supports loading recipe data from the backend, presenting recipes in a responsive card layout, filtering by base spirit and ABV range, sorting, pull-to-refresh, and paginated loading.

### Recipe Detail

The recipe detail page displays full recipe information and supports:

- Ingredient list
- Instructions
- Estimated ABV
- Like and favorite status
- Comment list and comment submission
- AI flavor analysis entry points

### Custom Recipe

The custom recipe page supports selecting ingredients, entering preparation steps, calculating estimated ABV, selecting an image, and creating AI-assisted cocktail recipes.

### User and Admin

The app includes user-facing profile/favorite/created-recipe pages and admin-facing management pages for users, recipes, and comments.

## Backend API Areas

The client integrates with APIs in these areas:

- Auth: login, register, logout, auth status
- Recipes: list, detail, delete, ratings
- Interactions: like, favorite, comments
- User: profile, avatar, signature, favorites, created recipes, likes
- Custom recipes: ingredients, create, update, delete, AI generation
- Recommendations: cached recommendation and scoring flows
- Admin: stats, users, recipes, comments

## Development Notes

1. Open the project with DevEco Studio.
2. Configure the backend base URL in the API service layer.
3. Make sure the backend service exposes the required `/api/...` routes.
4. Build and run on a HarmonyOS phone target.

## Status

This project is suitable for demonstrating a larger HarmonyOS client with multiple feature areas: recipe browsing, social interactions, user-generated content, AI-assisted creation, recommendations, theming, and admin tools.

