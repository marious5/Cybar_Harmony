// APIService.ets - API服务封装
// 对应 Swift 项目中的 APIService.swift

import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import preferences from '@ohos.data.preferences';
import { RecipesResponse, RecommendationsResponse } from '../models/Recipe';
import request from '@ohos.request';
import fs from '@ohos.file.fs';

interface AdminCommentsResponse {
  comments: AdminComment[];
  totalItems?: number;
}

// 适配后端 /api/recipes 的返回结构
interface AdminRecipesResponse {
  recipes: AdminRecipe[];
  totalPages?: number;
  currentPage?: number;
  sortBy?: string;
}

interface AdminUsersResponse {
  users: User[];
  totalItems: number;
  totalPages: number;
  currentPage: number;
}

// ✅ 修正：适配 server/routes/admin.js 返回的 { totalRecipes, totalUsers }
export interface AdminStats {
  totalUsers: number;
  totalRecipes: number;
}

// 自定义错误类
export class APIError extends Error {
  code: string;
  
  constructor(message: string, code: string = 'UNKNOWN') {
    super(message);
    this.code = code;
    this.name = 'APIError';
  }
}

export interface AdminUser {
  id: string;
  username: string;
  role: string;
  avatar: string;
  signature: string;
}

export interface AdminRecipe {
  id: string;
  name: string;
  createdBy: string;
  likeCount: number;
  favoriteCount: number;
  image?: string; // 配方图片路径
}

export interface AdminComment {
  id: string;
  user_name?: string;
  username: string;
  text: string;
  timestamp: string;
  recipeId?: string;
  recipeName?: string;
}

// API响应基础结构
export interface APIResponse<T> {
  success?: boolean;
  message: string;
  data: T;
}

// 用户信息
export interface User {
  id: string;
  username: string;
  role: string;
  avatar: string;
  signature: string;
}

// 认证状态
export interface AuthStatus {
  loggedIn: boolean;
  username?: string;
  role?: string;
}

// 登录状态缓存结构
interface LoginCache {
  username: string;
  role: string;
  cachedAt: number;
  cookie?: string;
}

const LOGIN_CACHE_KEY = 'loginCache';
const LOGIN_CACHE_MAX_AGE_MS = 90 * 24 * 60 * 60 * 1000; // 90 天

interface LoginResponseData {
  username?: string;
  role?: string;
  userRole?: string;
}

interface LoginResponseBody {
  message?: string;
  data?: LoginResponseData;
  username?: string;
  role?: string;
  userRole?: string;
}

interface LoginRequestBody {
  username: string;
  password: string;
}

interface CommentRequestBody {
  commentText: string;
}

interface UploadResult {
  success: boolean;
}

interface RequestHeaders {
  'Content-Type'?: string;
  Cookie?: string;
}

interface HeaderOptions {
  contentType?: string;
}

// 更新配方请求体（前端 JSON 方式）
interface UpdateRecipeRequestBody {
  name: string;
  description: string;
  estimatedAbv: string;
  ingredients: string; // JSON 字符串
  steps: string;       // JSON 字符串
  instructions: string;
}

// 状态变化监听器类型
type StateChangeListener = () => void;

// 推荐算法相关接口定义
interface UserInteraction {
  id: string;
  name: string;
  interactionType: 'like' | 'favorite';
  estimatedAbv: number;
  createdBy: string;
  ingredients: string;
}

interface UserPreferences {
  preferredAbv: number;
  topCreators: string[];
  ingredientWeights: Map<string, number>;
  interactedRecipeIds: Set<string>;
  avgRecipeWeight: number;
}

interface RecommendationScores {
  ingredientMatch: number;
  creatorMatch: number;
  abvMatch: number;
  popularity: number;
}

interface ScoredRecipe {
  id: string;
  name: string;
  image?: string;
  description?: string;
  estimatedAbv: number;
  createdBy: string;
  ingredients: string;
  likeCount: number;
  favoriteCount: number;
  scores: RecommendationScores;
  totalScore: number;
  matchReasons: string[];
}

// 定义配方数据接口
interface RecipeData {
  id: string;
  name: string;
  image?: string;
  description?: string;
  estimatedAbv: number;
  createdBy: string;
  ingredients: string;
  likeCount: number;
  favoriteCount: number;
}

// 推荐结果接口
interface RecommendationResult {
  id: string;
  name: string;
  image?: string;
  description?: string;
  estimatedAbv: number;
  matchPercentage: number;
  reason: string;
  reasons: string[];
  likeCount: number;
}

// 本地配方响应接口
interface LocalRecipesResponse {
  recipes?: RecipeData[];
}

// ==================== 二级缓存相关接口定义 ====================

// 缓存项接口
interface CacheItem<T> {
  data: T;
  timestamp: number;
  ttl: number; // 生存时间（毫秒）
  accessCount: number; // 访问次数，用于LRU策略
}

// L1缓存配置
interface L1CacheConfig {
  maxSize: number;        // 最大缓存项数
  defaultTTL: number;    // 默认TTL（毫秒）
}

// L2缓存配置
interface L2CacheConfig {
  maxSize: number;        // 最大缓存项数
  defaultTTL: number;    // 默认TTL（毫秒）
  compressionEnabled: boolean; // 是否启用压缩
}

// 缓存统计信息
interface CacheStats {
  l1Size: number;
  l2Size: number;
  l1HitRate: number;
  l2HitRate: number;
}

/**
 * ==================== 二级缓存管理器 ====================
 * 实现L1缓存（内存）+ L2缓存（持久化）的二级缓存系统
 */

// 二级缓存管理器
class TwoLevelCacheManager<T> {
  private l1Cache: Map<string, CacheItem<T>> = new Map();
  private l2Cache: Map<string, CacheItem<T>> = new Map();
  private l1Config: L1CacheConfig;
  private l2Config: L2CacheConfig;
  private preferences?: preferences.Preferences;
  private l2StorageKey: string;

  constructor(
    l1Config: L1CacheConfig,
    l2Config: L2CacheConfig,
    preferences?: preferences.Preferences,
    storageKey: string = 'two_level_cache'
  ) {
    this.l1Config = l1Config;
    this.l2Config = l2Config;
    this.preferences = preferences;
    this.l2StorageKey = storageKey;
    this.loadL2CacheFromStorage();
  }

  /**
   * 获取缓存项
   */
  async get(key: string): Promise<T | null> {
    const now = Date.now();

    // 1. 先从L1缓存查找
    const l1Item = this.l1Cache.get(key);
    if (l1Item && now - l1Item.timestamp < l1Item.ttl) {
      l1Item.accessCount++;
      console.info(`[Cache] L1命中: ${key}`);
      return l1Item.data;
    }

    // 2. L1未命中，从L2缓存查找
    const l2Item = this.l2Cache.get(key);
    if (l2Item && now - l2Item.timestamp < l2Item.ttl) {
      l2Item.accessCount++;
      console.info(`[Cache] L2命中: ${key}`);
      
      // 3. 将L2命中的数据提升到L1缓存
      this.promoteToL1(key, l2Item);
      return l2Item.data;
    }

    console.info(`[Cache] 未命中: ${key}`);
    return null;
  }

  /**
   * 设置缓存项
   */
  async set(key: string, data: T, customTTL?: number): Promise<void> {
    const now = Date.now();
    const ttl = customTTL || this.l1Config.defaultTTL;

    // 创建缓存项
    const cacheItem: CacheItem<T> = {
      data: data,
      timestamp: now,
      ttl: ttl,
      accessCount: 1
    };

    // 1. 存入L1缓存
    this.setL1Cache(key, cacheItem);

    // 2. 如果数据较大或重要，同时存入L2缓存
    if (this.shouldStoreInL2(data, key)) {
      this.setL2Cache(key, cacheItem);
    }

    // 3. 异步持久化L2缓存
    this.saveL2CacheToStorage();
  }

  /**
   * 删除缓存项
   */
  async delete(key: string): Promise<void> {
    this.l1Cache.delete(key);
    this.l2Cache.delete(key);
    await this.saveL2CacheToStorage();
    console.info(`[Cache] 删除: ${key}`);
  }

  /**
   * 清空所有缓存
   */
  async clear(): Promise<void> {
    this.l1Cache.clear();
    this.l2Cache.clear();
    await this.saveL2CacheToStorage();
    console.info('[Cache] 清空所有缓存');
  }

  /**
   * 获取缓存统计信息
   */
  getStats(): CacheStats {
    return {
      l1Size: this.l1Cache.size,
      l2Size: this.l2Cache.size,
      l1HitRate: this.calculateHitRate(this.l1Cache),
      l2HitRate: this.calculateHitRate(this.l2Cache)
    };
  }

  // 私有方法

  private setL1Cache(key: string, item: CacheItem<T>): void {
    // 检查L1缓存容量，执行LRU淘汰
    if (this.l1Cache.size >= this.l1Config.maxSize) {
      this.evictLRUFromL1();
    }
    this.l1Cache.set(key, item);
  }

  private setL2Cache(key: string, item: CacheItem<T>): void {
    // 检查L2缓存容量，执行LRU淘汰
    if (this.l2Cache.size >= this.l2Config.maxSize) {
      this.evictLRUFromL2();
    }
    this.l2Cache.set(key, item);
  }

  private promoteToL1(key: string, item: CacheItem<T>): void {
    // 将L2缓存项提升到L1
    const newItem: CacheItem<T> = {
      data: item.data,
      timestamp: item.timestamp,
      ttl: item.ttl,
      accessCount: item.accessCount
    };
    this.setL1Cache(key, newItem);
  }

  private shouldStoreInL2(data: T, key: string): boolean {
    // 判断是否应该存储到L2缓存
    // 可以基于数据大小、重要性等策略
    try {
      const dataSize = JSON.stringify(data).length;
      return dataSize > 1000 || key.includes('recommendation'); // 大数据或推荐数据存L2
    } catch {
      return false;
    }
  }

  private evictLRUFromL1(): void {
    let leastUsedKey: string | null = null;
    let minAccessCount = Infinity;

    const entries = this.l1Cache.entries();
    for (const entry of entries) {
      const key = entry[0];
      const item = entry[1];
      if (item.accessCount < minAccessCount) {
        minAccessCount = item.accessCount;
        leastUsedKey = key;
      }
    }

    if (leastUsedKey) {
      const evictedItem = this.l1Cache.get(leastUsedKey);
      if (evictedItem) {
        // 将淘汰的数据降级到L2缓存
        this.setL2Cache(leastUsedKey, evictedItem);
      }
      this.l1Cache.delete(leastUsedKey);
      console.info(`[Cache] L1 LRU淘汰: ${leastUsedKey}`);
    }
  }

  private evictLRUFromL2(): void {
    let leastUsedKey: string | null = null;
    let minAccessCount = Infinity;

    const entries = this.l2Cache.entries();
    for (const entry of entries) {
      const key = entry[0];
      const item = entry[1];
      if (item.accessCount < minAccessCount) {
        minAccessCount = item.accessCount;
        leastUsedKey = key;
      }
    }

    if (leastUsedKey) {
      this.l2Cache.delete(leastUsedKey);
      console.info(`[Cache] L2 LRU淘汰: ${leastUsedKey}`);
    }
  }

  private calculateHitRate(cache: Map<string, CacheItem<T>>): number {
    if (cache.size === 0) return 0;
    
    let totalAccess = 0;
    for (const item of cache.values()) {
      totalAccess += item.accessCount;
    }
    return totalAccess > 0 ? (totalAccess - cache.size) / totalAccess : 0;
  }

  private async loadL2CacheFromStorage(): Promise<void> {
    if (!this.preferences) return;

    try {
      const cacheData = await this.preferences.get(this.l2StorageKey, '') as string;
      if (cacheData) {
        const parsed: ESObject = JSON.parse(cacheData) as ESObject;
        if (parsed && parsed.items) {
          const items: ESObject = parsed.items as ESObject;
          const keys = Object.keys(items);
          for (let i = 0; i < keys.length; i++) {
            const key = keys[i];
            const item = items[key] as CacheItem<T>;
            // 检查是否过期
            if (Date.now() - item.timestamp < item.ttl) {
              this.l2Cache.set(key, item);
            }
          }
        }
      }
      console.info(`[Cache] 从存储加载L2缓存: ${this.l2Cache.size}项`);
    } catch (error) {
      console.error('[Cache] 加载L2缓存失败:', error);
    }
  }

  private async saveL2CacheToStorage(): Promise<void> {
    if (!this.preferences) return;

    try {
      const cacheDataObj: ESObject = {
        items: this.l2CacheToObject(),
        savedAt: Date.now()
      };
      
      const serialized = JSON.stringify(cacheDataObj);
      await this.preferences.put(this.l2StorageKey, serialized);
      await this.preferences.flush();
    } catch (error) {
      console.error('[Cache] 保存L2缓存失败:', error);
    }
  }

  /**
   * 将L2缓存转换为普通对象
   */
  private l2CacheToObject(): ESObject {
    const result: ESObject = {};
    const entries = this.l2Cache.entries();
    for (const entry of entries) {
      const key = entry[0];
      const item = entry[1];
      result[key] = item;
    }
    return result;
  }
}

/**
 * ==================== 环境配置 ====================
 * 切换环境：注释/取消注释下面的 BASE_URL 即可
 * =================================================
 */

// ⚠️ 开发环境 - 本地调试（使用时取消注释这行，注释掉生产环境）
// const BASE_URL: string = 'http://172.26.19.215:8080';
// const BASE_URL: string = 'http://10.0.2.2:80';
// const BASE_URL: string = 'http://192.168.43.231:8080';
// ⚠️ 生产环境 - 远程服务器（发布时取消注释这行，注释掉开发环境）
const BASE_URL: string = 'http://47.101.11.98:8080';

/**
 * API服务单例类
 * 提供与后端交互的网络服务
 * 使用观察者模式通知UI更新
 */
export default class APIService {
  private static instance: APIService;
  
  // 使用配置的baseURL
  private baseURL: string = BASE_URL;
  private context?: common.UIAbilityContext;
  private preferences?: preferences.Preferences;
  private authCookie: string = '';
  private loginCache?: LoginCache;
  
  // 当前登录状态 - 私有,通过 getter 访问
  private _isLoggedIn: boolean = false;
  private _currentUser?: User;
  
  // 状态变化监听器列表
  private listeners: StateChangeListener[] = [];
  
  // 推荐会话缓存 - 用于分层随机抽样
  private recommendationSessionCache: ScoredRecipe[] = [];
  private recommendationSessionSeed: number = 0;
  
  // 二级缓存管理器
  private recommendationCache: TwoLevelCacheManager<ScoredRecipe[]>;
  private userPreferencesCache: TwoLevelCacheManager<UserPreferences>;
  
  // 公开的 getter
  public get isLoggedIn(): boolean {
    return this._isLoggedIn;
  }
  
  public get currentUser(): User | undefined {
    return this._currentUser;
  }

  public get cachedLogin(): LoginCache | undefined {
    return this.loginCache;
  }

  // 暴露基础地址用于前端构造绝对资源 URL
  public getBaseURL(): string {
    return this.baseURL;
  }
  
  private constructor() {
    // 私有构造函数,确保单例模式
    
    // 初始化二级缓存 - L1缓存15项，L2缓存150项
    const l1Config: L1CacheConfig = {
      maxSize: 15,        // L1缓存最多15项
      defaultTTL: 5 * 60 * 1000  // 5分钟TTL
    };

    const l2Config: L2CacheConfig = {
      maxSize: 150,       // L2缓存最多150项
      defaultTTL: 30 * 60 * 1000, // 30分钟TTL
      compressionEnabled: false
    };

    this.recommendationCache = new TwoLevelCacheManager<ScoredRecipe[]>(
      l1Config, l2Config, undefined, 'recommendation_cache'
    );

    this.userPreferencesCache = new TwoLevelCacheManager<UserPreferences>(
      { maxSize: 5, defaultTTL: 10 * 60 * 1000 }, // 用户偏好缓存
      { maxSize: 20, defaultTTL: 60 * 60 * 1000, compressionEnabled: false },
      undefined, 'user_preferences_cache'
    );
  }
  
  /**
   * 获取APIService单例
   */
  public static getInstance(): APIService {
    if (!APIService.instance) {
      console.info('[APIService] Creating new APIService instance');
      APIService.instance = new APIService();
      console.info(`[APIService] Instance created - baseURL: ${APIService.instance.baseURL}`);
    }
    return APIService.instance;
  }
  
  /**
   * 添加状态变化监听器
   */
  public addListener(listener: StateChangeListener): void {
    this.listeners.push(listener);
  }
  
  /**
   * 移除状态变化监听器
   */
  public removeListener(listener: StateChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index > -1) {
      this.listeners.splice(index, 1);
    }
  }
  
  /**
   * 通知所有监听器状态已变化
   */
  private notifyListeners(): void {
    this.listeners.forEach(listener => listener());
  }
  
  /**
   * 更新登录状态并通知监听器
   */
  private updateLoginState(isLoggedIn: boolean, user?: User): void {
    this._isLoggedIn = isLoggedIn;
    this._currentUser = user;
    this.notifyListeners();
  }

  /**
   * 构建带有认证信息的请求头
   */
  private buildAuthHeaders(options?: HeaderOptions): RequestHeaders | undefined {
    const hasCookie = this.authCookie && this.authCookie.length > 0;
    const hasContentType = options && options.contentType && options.contentType.length > 0;

    if (!hasCookie && !hasContentType) {
      return undefined;
    }

    if (hasCookie && hasContentType) {
      return {
        'Content-Type': (options as HeaderOptions).contentType!,
        Cookie: this.authCookie
      };
    }

    if (hasContentType) {
      return {
        'Content-Type': (options as HeaderOptions).contentType!
      };
    }

    return {
      Cookie: this.authCookie
    };
  }

  private createRequestOptions(
    method: http.RequestMethod,
    headerOptions?: HeaderOptions,
    body?: Object
  ): http.HttpRequestOptions {
    const headers = this.buildAuthHeaders(headerOptions);
    const options: http.HttpRequestOptions = {
      method: method,
      expectDataType: http.HttpDataType.OBJECT
    };

    if (headers) {
      options.header = headers;
    }

    if (body) {
      options.extraData = body;
    }

    return options;
  }

  /**
   * 从响应头中提取服务端下发的会话 Cookie
   */
  private extractSessionCookie(response: http.HttpResponse): string | undefined {
    const headerObject: Object | undefined = response.header as Object;
    if (!headerObject) {
      return undefined;
    }

    const lowerCookie: ESObject = Reflect.get(headerObject, 'set-cookie') as ESObject;
    const upperCookie: ESObject = Reflect.get(headerObject, 'Set-Cookie') as ESObject;
    const normalized: ESObject = lowerCookie !== undefined ? lowerCookie : upperCookie;

    if (typeof normalized === 'string' && normalized.length > 0) {
      const parts = normalized.split(';');
      return parts.length > 0 ? parts[0] : normalized;
    }

    if (Array.isArray(normalized)) {
      const entries: Array<ESObject> = normalized as Array<ESObject>;
      const length = entries.length;
      for (let i = 0; i < length; i++) {
        const entry: ESObject = entries[i];
        if (typeof entry === 'string') {
          const entryStr: string = entry as string;
          if (entryStr.length > 0) {
            const parts = entryStr.split(';');
            return parts.length > 0 ? parts[0] : entryStr;
          }
        }
      }
    }

    return undefined;
  }
  
  /**
   * 初始化服务
   * @param context 应用上下文
   */
  public async initialize(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    
    // 初始化 preferences
    try {
      this.preferences = await preferences.getPreferences(context, 'apiservice');
      
      // 重新初始化二级缓存以使用preferences
      const l1Config: L1CacheConfig = {
        maxSize: 15,        // L1缓存最多15项
        defaultTTL: 5 * 60 * 1000  // 5分钟TTL
      };

      const l2Config: L2CacheConfig = {
        maxSize: 150,       // L2缓存最多150项
        defaultTTL: 30 * 60 * 1000, // 30分钟TTL
        compressionEnabled: false
      };

      this.recommendationCache = new TwoLevelCacheManager<ScoredRecipe[]>(
        l1Config, l2Config, this.preferences, 'recommendation_cache'
      );

      this.userPreferencesCache = new TwoLevelCacheManager<UserPreferences>(
        { maxSize: 5, defaultTTL: 10 * 60 * 1000 }, // 用户偏好缓存
        { maxSize: 20, defaultTTL: 60 * 60 * 1000, compressionEnabled: false },
        this.preferences, 'user_preferences_cache'
      );
      
    } catch (error) {
      console.error('[APIService] 初始化 preferences 失败:', error);
    }
    
    // 恢复本地登录状态缓存
    await this.restoreLoginFromCache();
    
    // 检查服务器状态
    await this.checkAuthStatus();
  }
  
  /**
   * 从本地缓存恢复登录状态
   */
  private async restoreLoginFromCache(): Promise<void> {
    if (!this.preferences) {
      return;
    }

    try {
      const cacheString = await this.preferences.get(LOGIN_CACHE_KEY, '') as string;
      if (!cacheString || cacheString.length === 0) {
        return;
      }

      const cache = JSON.parse(cacheString) as LoginCache | undefined;
      if (!cache) {
        return;
      }

      // 检查是否过期
      const now = Date.now();
      if (now - cache.cachedAt > LOGIN_CACHE_MAX_AGE_MS) {
        await this.clearLoginCache();
        return;
      }

      this.loginCache = cache;
      this.authCookie = cache.cookie ? cache.cookie : '';
      this.updateLoginState(true, {
        id: '',
        username: cache.username,
        role: cache.role,
        avatar: '',
        signature: ''
      });
    } catch (error) {
      console.error('[APIService] 恢复登录缓存失败:', error);
    }
  }

  /**
   * 持久化登录缓存
   */
  private async persistLoginCache(cache: LoginCache): Promise<void> {
    if (!this.preferences) {
      return;
    }

    try {
      this.loginCache = cache;
      this.authCookie = cache.cookie ? cache.cookie : '';
      await this.preferences.put(LOGIN_CACHE_KEY, JSON.stringify(cache));
      await this.preferences.flush();
    } catch (error) {
      console.error('[APIService] 保存登录缓存失败:', error);
    }
  }

  /**
   * 清除登录缓存
   */
  private async clearLoginCache(): Promise<void> {
    this.loginCache = undefined;
    this.authCookie = '';

    if (!this.preferences) {
      return;
    }

    try {
      await this.preferences.delete(LOGIN_CACHE_KEY);
      await this.preferences.flush();
    } catch (error) {
      console.error('[APIService] 清除登录缓存失败:', error);
    }
  }
  
  /**
   * 检查认证状态
   */
  public async checkAuthStatus(): Promise<void> {
    try {
      const url = `${this.baseURL}/api/auth/status`;
      const requestOptions = this.createRequestOptions(http.RequestMethod.GET);
      const response = await http.createHttp().request(url, requestOptions);
      
      if (response.responseCode === 200 && response.result) {
        const authStatus = response.result as AuthStatus;
        
        if (authStatus.loggedIn && authStatus.username && authStatus.role) {
          const user: User = {
            id: '',
            username: authStatus.username,
            role: authStatus.role,
            avatar: '',
            signature: ''
          };
          const cookie = this.extractSessionCookie(response);
          if (cookie && cookie.length > 0) {
            this.authCookie = cookie;
          }

          const cacheFromStatus: LoginCache = {
            username: authStatus.username,
            role: authStatus.role,
            cachedAt: Date.now(),
            cookie: this.authCookie
          };
          await this.persistLoginCache(cacheFromStatus);
          this.updateLoginState(true, user);
        } else {
          this.updateLoginState(false, undefined);
          await this.clearLoginCache();
        }
      }
    } catch (error) {
      console.error('[APIService] 检查认证状态失败:', error);
      if (!this.loginCache) {
        this.updateLoginState(false, undefined);
      }
    }
  }
  
  /**
   * 用户登录
   * @param username 用户名
   * @param password 密码
   */
  public async login(username: string, password: string): Promise<string> {
    try {
      const url = `${this.baseURL}/api/login`;
      const requestBody: LoginRequestBody = {
        username: username,
        password: password
      };
      const requestOptions = this.createRequestOptions(
        http.RequestMethod.POST,
        { contentType: 'application/json' },
        requestBody
      );
      const response = await http.createHttp().request(url, requestOptions);
      
      if (response.responseCode === 200) {
        const result = response.result as LoginResponseBody | undefined;
        let resolvedUsername: string = username;
        let resolvedRole: string = '';
        let message: string = '登录成功';

        if (result) {
          if (result.message && result.message.length > 0) {
            message = result.message;
          }

          let payload: LoginResponseData | undefined = undefined;
          if (result.data) {
            payload = result.data;
          } else {
            const fallbackPayload: LoginResponseData = {
              username: result.username,
              role: result.role,
              userRole: result.userRole
            };
            payload = fallbackPayload;
          }

          if (payload) {
            if (payload.username && payload.username.length > 0) {
              resolvedUsername = payload.username;
            }
            const roleCandidate = payload.role && payload.role.length > 0 ? payload.role : (payload.userRole ? payload.userRole : '');
            if (roleCandidate && roleCandidate.length > 0) {
              resolvedRole = roleCandidate;
            }
          }
        }

        const user: User = {
          id: '',
          username: resolvedUsername,
          role: resolvedRole,
          avatar: '',
          signature: ''
        };

        const cookie = this.extractSessionCookie(response);
        this.authCookie = cookie ? cookie : '';
        const cacheFromLogin: LoginCache = {
          username: user.username,
          role: user.role,
          cachedAt: Date.now(),
          cookie: this.authCookie
        };
        await this.persistLoginCache(cacheFromLogin);
        this.updateLoginState(true, user);

        return message;
      } else {
        const errorBody = response.result as LoginResponseBody | undefined;
        let message = '登录失败';
        if (errorBody && errorBody.message && errorBody.message.length > 0) {
          message = errorBody.message;
        }
        throw new APIError(message, 'LOGIN_FAILED');
      }
    } catch (error) {
      console.error('[APIService] 登录失败:', error);
      if (error instanceof APIError) {
        throw error;
      }
      throw new APIError('登录请求失败', 'NETWORK_ERROR');
    }
  }
  
  /**
   * 用户注册
   * @param username 用户名
   * @param password 密码
   */
  public async register(username: string, password: string): Promise<string> {
    try {
      const url = `${this.baseURL}/api/register`;
      const requestBody: LoginRequestBody = {
        username: username,
        password: password
      };
      const requestOptions = this.createRequestOptions(
        http.RequestMethod.POST,
        { contentType: 'application/json' },
        requestBody
      );
      const response = await http.createHttp().request(url, requestOptions);
      
      if (response.responseCode === 201) {
        return '注册成功';
      } else {
        const errorBody = response.result as LoginResponseBody | undefined;
        let message = '注册失败';
        if (errorBody && errorBody.message && errorBody.message.length > 0) {
          message = errorBody.message;
        }
        throw new APIError(message, 'REGISTER_FAILED');
      }
    } catch (error) {
      console.error('[APIService] 注册失败:', error);
      if (error instanceof APIError) {
        throw error;
      }
      throw new APIError('注册请求失败', 'NETWORK_ERROR');
    }
  }
  
  /**
   * 用户登出
   */
  public async logout(): Promise<void> {
    try {
      const url = `${this.baseURL}/api/logout`;
      const requestOptions = this.createRequestOptions(http.RequestMethod.POST);
      await http.createHttp().request(url, requestOptions);

      await this.clearLoginCache();
      this.authCookie = '';
      this.updateLoginState(false, undefined);
    } catch (error) {
      console.error('[APIService] 登出失败:', error);
      throw new APIError('登出请求失败', 'NETWORK_ERROR');
    }
  }

  /**
   * 获取配方列表
   * @param page 页码
   * @param limit 每页数量
   * @param search 搜索关键词
   * @param sort 排序方式
   */
  public async fetchRecipes(
    page: number = 1,
    limit: number = 10,
    search: string = '',
    sort: string = 'default'
  ): Promise<object> {
    const httpRequest = http.createHttp();
    
    try {
      const url = `${this.baseURL}/api/recipes?page=${page}&limit=${limit}&search=${encodeURIComponent(search)}&sort=${sort}`;
      console.info(`[APIService] fetchRecipes - URL: ${url}`);
      
      // 配置请求选项 - 确保正确的超时和数据类型
      const requestOptions: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.OBJECT,
        connectTimeout: 10000,  // 10秒连接超时
        readTimeout: 10000      // 10秒读取超时
      };
      
      console.info(`[APIService] fetchRecipes - Sending request...`);
      const response = await httpRequest.request(url, requestOptions);
      
      console.info(`[APIService] fetchRecipes - Response code: ${response.responseCode}`);
      
      if (response.responseCode === 200) {
        const result = response.result as object;
        console.info(`[APIService] fetchRecipes - SUCCESS - Got ${Object.keys(result).length} keys`);
        
        const recipes = Reflect.get(result, 'recipes') as Array<object> | null;
        if (recipes && Array.isArray(recipes)) {
          console.info(`[APIService] fetchRecipes - Got ${recipes.length} recipes`);
        }
        
        return result;
      } else {
        console.error(`[APIService] fetchRecipes - HTTP Error ${response.responseCode}`);
        throw new APIError(`获取配方列表失败 (${response.responseCode})`, 'FETCH_FAILED');
      }
    } catch (error) {
      console.error('[APIService] fetchRecipes - Exception:', error);
      
      if (error instanceof APIError) {
        throw error;
      }
      
      // 处理网络错误
      throw new APIError('网络请求失败，请检查网络连接', 'NETWORK_ERROR');
    } finally {
      // 清理HTTP连接
      httpRequest.destroy();
    }
  }

  /**
   * 获取配方详情
   * @param id 配方ID
   * 对应 server.js: GET /api/recipes/:id
   */
  public async fetchRecipeDetail(id: string): Promise<object> {
    try {
      const url = `${this.baseURL}/api/recipes/${id}`;
      const requestOptions = this.createRequestOptions(http.RequestMethod.GET);
      const response = await http.createHttp().request(url, requestOptions);
      
      if (response.responseCode === 200) {
        return response.result as object;
      } else {
        throw new APIError('获取配方详情失败', 'FETCH_FAILED');
      }
    } catch (error) {
      console.error('[APIService] 获取配方详情失败:', error);
      if (error instanceof APIError) {
        throw error;
      }
      throw new APIError('获取配方详情请求失败', 'NETWORK_ERROR');
    }
  }

  /**
   * 获取配方交互状态 (点赞和收藏)
   * @param recipeId 配方ID
   * 对应 server.js: GET /api/recipes/:id/interactions
   */
  public async fetchRecipeInteractionStatus(recipeId: string): Promise<object> {
    try {
      const url = `${this.baseURL}/api/recipes/${recipeId}/interactions`;
      const requestOptions = this.createRequestOptions(http.RequestMethod.GET);
      const response = await http.createHttp().request(url, requestOptions);
      
      if (response.responseCode === 200) {
        return response.result as object;
      } else {
        throw new APIError('获取交互状态失败', 'FETCH_FAILED');
      }
    } catch (error) {
      console.error('[APIService] 获取交互状态失败:', error);
      if (error instanceof APIError) {
        throw error;
      }
      throw new APIError('获取交互状态请求失败', 'NETWORK_ERROR');
    }
  }
  
  /**
   * 获取推荐列表（支持分页）- 现调用recipes接口并在本地实现推荐算法
   * 使用分层随机抽样：将推荐按匹配度分为高/中/低三层，每页随机混合抽取
   * @param page 页码（从1开始）
   * @param limit 每页数量
   * @param forceRefresh 是否强制刷新（下拉刷新时传true）
   */
  public async fetchRecommendations(page: number = 1, limit: number = 10, forceRefresh: boolean = false): Promise<RecommendationsResponse> {
    try {
      // 如果强制刷新或第一页且缓存为空，重新生成随机序列
      if (forceRefresh || (page === 1 && this.recommendationSessionCache.length === 0)) {
        this.resetRecommendationSession();
        
        // 1. 获取用户的点赞和收藏数据（未登录时返回空数组）
        let userInteractions: UserInteraction[] = [];
        if (this._isLoggedIn) {
          userInteractions = await this.getUserInteractions();
        }
        
        // 2. 获取所有候选配方（调用recipes接口）
        const allRecipesData: object = await this.getAllRecipes();
        const recipesResponse = allRecipesData as LocalRecipesResponse;
        if (!recipesResponse || !recipesResponse.recipes) {
          throw new APIError('获取配方数据失败', 'FETCH_FAILED');
        }

        let scoredRecipes: ScoredRecipe[] = [];
        let isPopularityOnly = false;
        
        // 获取当前用户名（用于过滤自己创建的配方）
        const currentUsername = this._isLoggedIn && this._currentUser ? this._currentUser.username : '';
        
        // 未登录或无用户交互数据时，使用人气得分推荐
        if (!this._isLoggedIn || userInteractions.length === 0) {
          // 过滤掉当前用户创建的配方
          const candidateRecipes: RecipeData[] = [];
          recipesResponse.recipes.forEach((recipe: RecipeData) => {
            if (!currentUsername || recipe.createdBy !== currentUsername) {
              candidateRecipes.push(recipe);
            }
          });
          scoredRecipes = this.calculatePopularityOnlyScores(candidateRecipes);
          isPopularityOnly = true;
          console.info(`[APIService] 使用人气推荐模式 (登录状态: ${this._isLoggedIn}, 交互数据: ${userInteractions.length}条, 过滤自创配方: ${currentUsername || '无'})`);
        } else {
          // 3. 分析用户偏好
          const userPreferences = this.analyzeUserPreferences(userInteractions);

          // 4. 过滤掉用户已交互的配方和自己创建的配方
          const candidateRecipes: RecipeData[] = [];
          recipesResponse.recipes.forEach((recipe: RecipeData) => {
            const isOwnRecipe = currentUsername && recipe.createdBy === currentUsername;
            if (!userPreferences.interactedRecipeIds.has(recipe.id) && !isOwnRecipe) {
              candidateRecipes.push(recipe);
            }
          });

          // 5. 计算推荐得分
          scoredRecipes = this.calculateRecommendationScores(candidateRecipes, userPreferences);
        }

        // 6. 使用分层随机抽样生成本次会话的推荐序列
        this.recommendationSessionCache = this.layeredRandomSampling(scoredRecipes, isPopularityOnly);
        console.info(`[APIService] 生成新的推荐会话，共${this.recommendationSessionCache.length}个推荐`);
      }

      // 7. 从缓存中分页获取
      const startIndex = (page - 1) * limit;
      const endIndex = startIndex + limit;
      const paginatedRecipes: ScoredRecipe[] = [];
      for (let i = startIndex; i < Math.min(endIndex, this.recommendationSessionCache.length); i++) {
        paginatedRecipes.push(this.recommendationSessionCache[i]);
      }

      // 8. 格式化返回数据
      const recommendations: RecommendationResult[] = [];
      paginatedRecipes.forEach((recipe: ScoredRecipe) => {
        recommendations.push(this.formatRecommendation(recipe));
      });

      const totalPages = Math.ceil(this.recommendationSessionCache.length / limit);
      console.info(`[APIService] 推荐加载成功: 第${page}页/${totalPages}页, ${recommendations.length}条`);
      
      return {
        recommendations,
        pagination: {
          currentPage: page,
          totalPages: totalPages,
          totalRecommendations: this.recommendationSessionCache.length,
          limit: limit,
          hasMore: page < totalPages
        }
      };

    } catch (error) {
      console.error('[APIService] 获取推荐列表失败:', error);
      return { recommendations: [], message: '加载失败' };
    }
  }

  /**
   * 获取推荐列表（使用二级缓存优化版本）
   * @param page 页码（从1开始）
   * @param limit 每页数量
   * @param forceRefresh 是否强制刷新（下拉刷新时传true）
   */
  public async fetchRecommendationsWithCache(
    page: number = 1, 
    limit: number = 10, 
    forceRefresh: boolean = false
  ): Promise<RecommendationsResponse> {
    try {
      const cacheKey = `recommendations_${page}_${limit}_${this._currentUser?.username || 'anonymous'}`;
      
      // 1. 检查缓存（除非强制刷新）
      if (!forceRefresh) {
        const cachedRecommendations = await this.recommendationCache.get(cacheKey);
        if (cachedRecommendations) {
          console.info(`[APIService] 推荐缓存命中: ${cacheKey}`);
          return this.formatCachedRecommendations(cachedRecommendations, page, limit);
        }
      }

      // 2. 缓存未命中或强制刷新，重新计算
      console.info(`[APIService] 重新计算推荐: ${cacheKey}`);
      
      // 检查用户偏好缓存
      const preferencesCacheKey = `user_prefs_${this._currentUser?.username || 'anonymous'}`;
      let userPreferences = await this.userPreferencesCache.get(preferencesCacheKey);
      
      if (!userPreferences) {
        // 重新计算用户偏好
        let userInteractions: UserInteraction[] = [];
        if (this._isLoggedIn) {
          userInteractions = await this.getUserInteractions();
        }
        userPreferences = this.analyzeUserPreferences(userInteractions);
        await this.userPreferencesCache.set(preferencesCacheKey, userPreferences);
      }

      // 获取所有配方并计算推荐
      const allRecipesData = await this.getAllRecipes();
      const recipesResponse = allRecipesData as LocalRecipesResponse;
      
      if (!recipesResponse || !recipesResponse.recipes) {
        throw new APIError('获取配方数据失败', 'FETCH_FAILED');
      }

      let scoredRecipes: ScoredRecipe[] = [];
      let isPopularityOnly = false;
      
      // 获取当前用户名（用于过滤自己创建的配方）
      const currentUsername = this._isLoggedIn && this._currentUser ? this._currentUser.username : '';
      
      // 未登录或无用户交互数据时，使用人气得分推荐
      if (!this._isLoggedIn || (userPreferences && userPreferences.interactedRecipeIds.size === 0)) {
        // 过滤掉当前用户创建的配方
        const candidateRecipes: RecipeData[] = [];
        recipesResponse.recipes.forEach((recipe: RecipeData) => {
          if (!currentUsername || recipe.createdBy !== currentUsername) {
            candidateRecipes.push(recipe);
          }
        });
        scoredRecipes = this.calculatePopularityOnlyScores(candidateRecipes);
        isPopularityOnly = true;
        console.info(`[APIService] 使用人气推荐模式 (登录状态: ${this._isLoggedIn}, 交互数据: ${userPreferences ? userPreferences.interactedRecipeIds.size : 0}条, 过滤自创配方: ${currentUsername || '无'})`);
      } else {
        // 过滤掉用户已交互的配方和自己创建的配方
        const candidateRecipes: RecipeData[] = [];
        recipesResponse.recipes.forEach((recipe: RecipeData) => {
          const isOwnRecipe = currentUsername && recipe.createdBy === currentUsername;
          if (userPreferences && !userPreferences.interactedRecipeIds.has(recipe.id) && !isOwnRecipe) {
            candidateRecipes.push(recipe);
          }
        });

        // 计算推荐得分
        if (userPreferences) {
          scoredRecipes = this.calculateRecommendationScores(candidateRecipes, userPreferences);
        }
      }

      // 生成分层随机抽样结果
      const recommendations = this.layeredRandomSampling(scoredRecipes, isPopularityOnly);

      // 缓存结果
      await this.recommendationCache.set(cacheKey, recommendations);

      // 格式化并返回
      return this.formatCachedRecommendations(recommendations, page, limit);

    } catch (error) {
      console.error('[APIService] 获取推荐列表失败:', error);
      return { recommendations: [], message: '加载失败' };
    }
  }

  /**
   * 格式化缓存的推荐结果
   */
  private formatCachedRecommendations(
    recommendations: ScoredRecipe[], 
    page: number, 
    limit: number
  ): RecommendationsResponse {
    const startIndex = (page - 1) * limit;
    const endIndex = startIndex + limit;
    const paginatedRecipes: ScoredRecipe[] = [];
    
    for (let i = startIndex; i < Math.min(endIndex, recommendations.length); i++) {
      paginatedRecipes.push(recommendations[i]);
    }

    const formattedRecommendations: RecommendationResult[] = [];
    paginatedRecipes.forEach((recipe: ScoredRecipe) => {
      formattedRecommendations.push(this.formatRecommendation(recipe));
    });

    const totalPages = Math.ceil(recommendations.length / limit);
    
    return {
      recommendations: formattedRecommendations,
      pagination: {
        currentPage: page,
        totalPages: totalPages,
        totalRecommendations: recommendations.length,
        limit: limit,
        hasMore: page < totalPages
      }
    };
  }

  /**
   * 获取用户交互数据（点赞和收藏）
   */
  private async getUserInteractions(): Promise<UserInteraction[]> {
    const interactions: UserInteraction[] = [];
    
    try {
      // 获取用户点赞的配方
      const likes: object[] = await this.fetchUserLikes();
      likes.forEach((recipe: object) => {
        const recipeData = recipe as RecipeData;
        interactions.push({
          id: recipeData.id || '',
          name: recipeData.name || '',
          interactionType: 'like',
          estimatedAbv: recipeData.estimatedAbv || 0,
          createdBy: recipeData.createdBy || '',
          ingredients: recipeData.ingredients || ''
        });
      });

      // 获取用户收藏的配方
      const favorites: object[] = await this.fetchUserFavorites();
      favorites.forEach((recipe: object) => {
        const recipeData = recipe as RecipeData;
        interactions.push({
          id: recipeData.id || '',
          name: recipeData.name || '',
          interactionType: 'favorite',
          estimatedAbv: recipeData.estimatedAbv || 0,
          createdBy: recipeData.createdBy || '',
          ingredients: recipeData.ingredients || ''
        });
      });

    } catch (error) {
      console.error('[APIService] 获取用户交互数据失败:', error);
    }

    return interactions;
  }

  /**
   * 分析用户偏好
   */
  private analyzeUserPreferences(interactions: UserInteraction[]): UserPreferences {
    const preferences: UserPreferences = {
      preferredAbv: 0,
      topCreators: [],
      ingredientWeights: new Map(),
      interactedRecipeIds: new Set(),
      avgRecipeWeight: 1
    };

    // 记录已交互的配方ID
    interactions.forEach(interaction => {
      preferences.interactedRecipeIds.add(interaction.id);
    });

    // 计算偏好酒精度（中位数）
    const abvList = interactions
      .filter(i => i.estimatedAbv > 0)
      .map(i => i.estimatedAbv)
      .sort((a, b) => a - b);
    
    if (abvList.length > 0) {
      const mid = Math.floor(abvList.length / 2);
      preferences.preferredAbv = abvList.length % 2 === 1
        ? abvList[mid]
        : (abvList[mid - 1] + abvList[mid]) / 2;
    }

    // 统计创建者偏好
    const creatorMap = new Map<string, number>();
    interactions.forEach(interaction => {
      if (interaction.createdBy) {
        const count = creatorMap.get(interaction.createdBy) || 0;
        creatorMap.set(interaction.createdBy, count + 1);
      }
    });
    const creatorPairs: [string, number][] = [];
    creatorMap.forEach((count, creator) => {
      creatorPairs.push([creator, count]);
    });
    creatorPairs.sort((a: [string, number], b: [string, number]) => b[1] - a[1]);
    
    preferences.topCreators = [];
    for (let i = 0; i < Math.min(3, creatorPairs.length); i++) {
      preferences.topCreators.push(creatorPairs[i][0]);
    }

    // 分析原料偏好
    let totalWeight = 0;
    interactions.forEach(interaction => {
      const weight = interaction.interactionType === 'favorite' ? 2 : 1;
      totalWeight += weight;
      
      if (interaction.ingredients) {
        const ingredients = interaction.ingredients.split(',');
        ingredients.forEach(rawIng => {
          const ingredient = this.normalizeIngredient(rawIng.trim());
          const currentWeight = preferences.ingredientWeights.get(ingredient) || 0;
          preferences.ingredientWeights.set(ingredient, currentWeight + weight);
        });
      }
    });

    preferences.avgRecipeWeight = interactions.length > 0 ? totalWeight / interactions.length : 1;

    return preferences;
  }

  /**
   * 规范化原料名称
   */
  private normalizeIngredient(ingredient: string): string {
    const ingredientNormalizationMap: Record<string, string> = {
      "金酒 (gin)": "金酒",
      "gin": "金酒",
      "伏特加 (vodka)": "伏特加",
      "vodka": "伏特加",
      "朗姆酒 (rum)": "朗姆酒",
      "rum": "朗姆酒",
      "龙舌兰 (tequila)": "龙舌兰",
      "tequila": "龙舌兰",
      "威士忌 (whiskey)": "威士忌",
      "whiskey": "威士忌",
      "whisky": "威士忌",
      "白兰地 (brandy)": "白兰地",
      "brandy": "白兰地",
      "利口酒 (liqueur)": "利口酒",
      "liqueur": "利口酒",
      "苦精 (bitters)": "苦精",
      "bitters": "苦精",
      "苏打水 (soda)": "苏打水",
      "soda": "苏打水",
      "汤力水 (tonic)": "汤力水",
      "tonic": "汤力水",
      "柠檬汁 (lemon juice)": "柠檬汁",
      "lemon juice": "柠檬汁",
      "青柠汁 (lime juice)": "青柠汁",
      "lime juice": "青柠汁"
    };

    const lowerIngredient = ingredient.toLowerCase().trim();
    const keys = Object.keys(ingredientNormalizationMap);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const value = ingredientNormalizationMap[key];
      if (lowerIngredient === key.toLowerCase()) {
        return value;
      }
    }
    return ingredient.replace(/\(.*?\)/g, '').trim();
  }

  /**
   * 获取所有配方数据
   */
  private async getAllRecipes(): Promise<object> {
    try {
      // 获取足够多的配方用于推荐计算，设置较大的limit
      const response: object = await this.fetchRecipes(1, 1000, '', 'default');
      return response;
    } catch (error) {
      console.error('[APIService] 获取所有配方失败:', error);
      throw new APIError('获取配方数据失败', 'FETCH_FAILED');
    }
  }

  /**
   * 计算推荐得分
   */
  private calculateRecommendationScores(recipes: RecipeData[], preferences: UserPreferences): ScoredRecipe[] {
    const results: ScoredRecipe[] = [];
    
    recipes.forEach((recipe: RecipeData) => {
      const scores: RecommendationScores = {
        ingredientMatch: 0,
        creatorMatch: 0,
        abvMatch: 0,
        popularity: 0
      };
      const matchReasons: string[] = [];

      // 原料匹配得分 (权重 4)
      if (recipe.ingredients) {
        const ingredientList: string[] = recipe.ingredients.split(',');
        const recipeIngredients: string[] = [];
        ingredientList.forEach((ing: string) => {
          recipeIngredients.push(this.normalizeIngredient(ing.trim()));
        });
        
        let rawIngredientScore = 0;
        recipeIngredients.forEach((ing: string) => {
          const weight = preferences.ingredientWeights.get(ing) || 0;
          rawIngredientScore += weight;
        });

        const smoothFactor = 0.5;
        scores.ingredientMatch = 4 * (rawIngredientScore / (preferences.avgRecipeWeight + smoothFactor));
        scores.ingredientMatch = Math.min(scores.ingredientMatch, 4);

        const commonIngredients: string[] = [];
        recipeIngredients.forEach((ing: string) => {
          if (preferences.ingredientWeights.has(ing)) {
            commonIngredients.push(ing);
          }
        });
        
        if (commonIngredients.length > 0) {
          const displayIngredients: string[] = [];
          for (let i = 0; i < Math.min(3, commonIngredients.length); i++) {
            displayIngredients.push(commonIngredients[i]);
          }
          const display = displayIngredients.join('、');
          matchReasons.push(`可能喜欢的原料: ${display}${commonIngredients.length > 3 ? '等' : ''}`);
        }
      }

      // 创建者匹配得分 (权重 3)
      if (recipe.createdBy && preferences.topCreators.includes(recipe.createdBy)) {
        scores.creatorMatch = 3;
        matchReasons.push(`可能喜欢的调酒师: ${recipe.createdBy}`);
      }

      // 酒精度匹配得分 (权重 2)
      if (preferences.preferredAbv > 0 && recipe.estimatedAbv > 0) {
        const diff = Math.abs(recipe.estimatedAbv - preferences.preferredAbv);
        scores.abvMatch = Math.max(0, 2 * (1 - diff / 20));
        if (scores.abvMatch > 1.0) {
          matchReasons.push(`可能喜欢的酒精浓度: ${recipe.estimatedAbv}%`);
        }
      }

      // 人气得分 (权重 1.5)
      const totalInteractions = (recipe.likeCount || 0) + (recipe.favoriteCount || 0);
      if (totalInteractions > 0) {
        scores.popularity = Math.min(1.5, 1.5 * Math.log(1 + totalInteractions / 50));
        if (totalInteractions > 10) {
          matchReasons.push(`热门配方 (已有${totalInteractions}次👍&⭐)`);
        }
      }

      const totalScore = scores.ingredientMatch + scores.creatorMatch + scores.abvMatch + scores.popularity;

      const scoredRecipe: ScoredRecipe = {
        id: recipe.id,
        name: recipe.name,
        image: recipe.image,
        description: recipe.description,
        estimatedAbv: recipe.estimatedAbv,
        createdBy: recipe.createdBy,
        ingredients: recipe.ingredients,
        likeCount: recipe.likeCount,
        favoriteCount: recipe.favoriteCount,
        scores: scores,
        totalScore: totalScore,
        matchReasons: matchReasons
      };
      
      results.push(scoredRecipe);
    });
    
    return results;
  }

  /**
   * 仅基于人气得分计算推荐（无用户交互数据时使用）
   */
  private calculatePopularityOnlyScores(recipes: RecipeData[]): ScoredRecipe[] {
    const results: ScoredRecipe[] = [];
    
    recipes.forEach((recipe: RecipeData) => {
      const scores: RecommendationScores = {
        ingredientMatch: 0,
        creatorMatch: 0,
        abvMatch: 0,
        popularity: 0
      };
      const matchReasons: string[] = [];

      // 仅计算人气得分 (权重 10，作为唯一指标)
      const totalInteractions = (recipe.likeCount || 0) + (recipe.favoriteCount || 0);
      if (totalInteractions > 0) {
        scores.popularity = Math.min(10, 10 * Math.log(1 + totalInteractions / 10));
        if (totalInteractions > 5) {
          matchReasons.push(`热门配方 (已有${totalInteractions}次👍&⭐)`);
        }
      }

      // 添加默认推荐理由
      if (matchReasons.length === 0) {
        matchReasons.push('为您精选的配方');
      }

      const totalScore = scores.popularity;

      const scoredRecipe: ScoredRecipe = {
        id: recipe.id,
        name: recipe.name,
        image: recipe.image,
        description: recipe.description,
        estimatedAbv: recipe.estimatedAbv,
        createdBy: recipe.createdBy,
        ingredients: recipe.ingredients,
        likeCount: recipe.likeCount,
        favoriteCount: recipe.favoriteCount,
        scores: scores,
        totalScore: totalScore,
        matchReasons: matchReasons
      };
      
      results.push(scoredRecipe);
    });
    
    return results;
  }

  /**
   * 格式化推荐结果
   */
  private formatRecommendation(recipe: ScoredRecipe): RecommendationResult {
    // 判断是否为仅人气推荐（其他得分都为0时）
    const isPopularityOnly = recipe.scores.ingredientMatch === 0 && 
                             recipe.scores.creatorMatch === 0 && 
                             recipe.scores.abvMatch === 0;
    const maxPossibleScore = isPopularityOnly ? 10 : (4 + 3 + 2 + 1.5); // 总权重
    const matchPercentage = Math.min(100, Math.round((recipe.totalScore / maxPossibleScore) * 100));

    let reasons: string[] = [];
    for (let i = 0; i < Math.min(3, recipe.matchReasons.length); i++) {
      reasons.push(recipe.matchReasons[i]);
    }
    if (reasons.length === 0) {
      reasons = ['您可能喜欢的新配方'];
    }
    const reasonText = reasons.join(' • ');

    const result: RecommendationResult = {
      id: recipe.id,
      name: recipe.name,
      image: recipe.image,
      description: recipe.description,
      estimatedAbv: recipe.estimatedAbv,
      matchPercentage: matchPercentage,
      reason: reasonText,
      reasons: reasons,
      likeCount: recipe.likeCount || 0
    };

    return result;
  }

  /**
   * 使用种子的伪随机数生成器
   */
  private seededRandom(seed: number): () => number {
    let currentSeed = seed;
    return (): number => {
      currentSeed = (currentSeed * 1103515245 + 12345) & 0x7fffffff;
      return currentSeed / 0x7fffffff;
    };
  }

  /**
   * 使用Fisher-Yates算法打乱数组（带种子）
   */
  private shuffleArrayWithSeed<T>(array: T[], seed: number): T[] {
    const result = [...array];
    const random = this.seededRandom(seed);
    for (let i = result.length - 1; i > 0; i--) {
      const j = Math.floor(random() * (i + 1));
      const temp = result[i];
      result[i] = result[j];
      result[j] = temp;
    }
    return result;
  }

  /**
   * 将推荐结果按排名分层
   * 先按得分排序，然后按排名位置分为三层：
   * 高匹配层：排名前1/3、中匹配层：排名中间1/3、低匹配层：排名后1/3
   */
  private tierRecommendations(scoredRecipes: ScoredRecipe[], isPopularityOnly: boolean): Map<string, ScoredRecipe[]> {
    const tiers = new Map<string, ScoredRecipe[]>();
    tiers.set('high', []);
    tiers.set('medium', []);
    tiers.set('low', []);

    // 先按得分降序排序
    const sortedRecipes = [...scoredRecipes].sort((a, b) => b.totalScore - a.totalScore);
    const totalCount = sortedRecipes.length;
    
    if (totalCount === 0) {
      return tiers;
    }

    // 按排名分层：前1/3为高，中间1/3为中，后1/3为低
    const highCutoff = Math.ceil(totalCount / 3);
    const mediumCutoff = Math.ceil(totalCount * 2 / 3);

    sortedRecipes.forEach((recipe: ScoredRecipe, index: number) => {
      if (index < highCutoff) {
        tiers.get('high')!.push(recipe);
      } else if (index < mediumCutoff) {
        tiers.get('medium')!.push(recipe);
      } else {
        tiers.get('low')!.push(recipe);
      }
    });

    console.info(`[APIService] 按排名分层: 总${totalCount}个, 高${tiers.get('high')!.length}个, 中${tiers.get('medium')!.length}个, 低${tiers.get('low')!.length}个`);
    return tiers;
  }

  /**
   * 分层随机抽样生成推荐列表
   * 每页从各层按比例随机抽取：高层50%，中层35%，低层15%
   */
  private layeredRandomSampling(scoredRecipes: ScoredRecipe[], isPopularityOnly: boolean): ScoredRecipe[] {
    // 使用当前会话种子进行分层
    const tiers = this.tierRecommendations(scoredRecipes, isPopularityOnly);
    
    // 打乱每个层级内部的顺序
    const shuffledHigh = this.shuffleArrayWithSeed(tiers.get('high')!, this.recommendationSessionSeed);
    const shuffledMedium = this.shuffleArrayWithSeed(tiers.get('medium')!, this.recommendationSessionSeed + 1);
    const shuffledLow = this.shuffleArrayWithSeed(tiers.get('low')!, this.recommendationSessionSeed + 2);

    // 按比例交替抽取，形成最终列表
    // 策略：每5个位置分配为 [高, 高, 高, 中, 中, 中, 低, 低, 中, 高] 的循环模式
    const result: ScoredRecipe[] = [];
    let highIndex = 0;
    let mediumIndex = 0;
    let lowIndex = 0;

    // 定义抽取模式：0=高, 1=中, 2=低
    const pattern = [0, 0, 1, 0, 1, 0, 2, 1, 1, 2];
    let patternIndex = 0;

    const totalCount = shuffledHigh.length + shuffledMedium.length + shuffledLow.length;

    while (result.length < totalCount) {
      const tier = pattern[patternIndex % pattern.length];
      patternIndex++;

      if (tier === 0 && highIndex < shuffledHigh.length) {
        result.push(shuffledHigh[highIndex++]);
      } else if (tier === 1 && mediumIndex < shuffledMedium.length) {
        result.push(shuffledMedium[mediumIndex++]);
      } else if (tier === 2 && lowIndex < shuffledLow.length) {
        result.push(shuffledLow[lowIndex++]);
      } else {
        // 当前层已用完，尝试从其他层抽取
        if (highIndex < shuffledHigh.length) {
          result.push(shuffledHigh[highIndex++]);
        } else if (mediumIndex < shuffledMedium.length) {
          result.push(shuffledMedium[mediumIndex++]);
        } else if (lowIndex < shuffledLow.length) {
          result.push(shuffledLow[lowIndex++]);
        }
      }
    }

    console.info(`[APIService] 分层随机抽样完成: 高匹配${shuffledHigh.length}个, 中匹配${shuffledMedium.length}个, 低匹配${shuffledLow.length}个`);
    return result;
  }
  
  /**
   * 切换点赞状态
   * @param recipeId 配方ID
   */
  public async toggleLike(recipeId: string): Promise<object> {
    try {
      const url = `${this.baseURL}/api/recipes/${recipeId}/like`;
      const requestOptions = this.createRequestOptions(http.RequestMethod.POST);
      const response = await http.createHttp().request(url, requestOptions);
      
      if (response.responseCode === 200) {
        return response.result as object;
      } else {
        throw new APIError('点赞操作失败', 'OPERATION_FAILED');
      }
    } catch (error) {
      console.error('[APIService] 点赞操作失败:', error);
      if (error instanceof APIError) {
        throw error;
      }
      throw new APIError('点赞请求失败', 'NETWORK_ERROR');
    }
  }
  
  /**
   * 切换收藏状态
   * @param recipeId 配方ID
   */
  public async toggleFavorite(recipeId: string): Promise<object> {
    try {
      const url = `${this.baseURL}/api/recipes/${recipeId}/favorite`;
      const requestOptions = this.createRequestOptions(http.RequestMethod.POST);
      const response = await http.createHttp().request(url, requestOptions);
      
      if (response.responseCode === 200) {
        return response.result as object;
      } else {
        throw new APIError('收藏操作失败', 'OPERATION_FAILED');
      }
    } catch (error) {
      console.error('[APIService] 收藏操作失败:', error);
      if (error instanceof APIError) {
        throw error;
      }
      throw new APIError('收藏请求失败', 'NETWORK_ERROR');
    }
  }
  
  /**
   * 获取评论列表
   * @param recipeId 配方ID
   */
  public async fetchComments(recipeId: string): Promise<Array<object>> {
    try {
      const url = `${this.baseURL}/api/recipes/${recipeId}/comments`;
      const requestOptions = this.createRequestOptions(http.RequestMethod.GET);
      const response = await http.createHttp().request(url, requestOptions);
      
      if (response.responseCode === 200) {
        return response.result as Array<object>;
      } else {
        throw new APIError('获取评论失败', 'FETCH_FAILED');
      }
    } catch (error) {
      console.error('[APIService] 获取评论失败:', error);
      return [];
    }
  }
  
  /**
   * 添加评论
   * @param recipeId 配方ID
   * @param text 评论内容
   * 对应 server.js: POST /api/recipes/:id/comments
   */
  public async addComment(recipeId: string, text: string): Promise<object> {
    try {
      const url = `${this.baseURL}/api/recipes/${recipeId}/comments`;
      const requestBody: CommentRequestBody = {
        commentText: text
      };
      const requestOptions = this.createRequestOptions(
        http.RequestMethod.POST,
        { contentType: 'application/json' },
        requestBody
      );
      const response = await http.createHttp().request(url, requestOptions);
      
      // server.js 返回 201 Created
      if (response.responseCode === 201 || response.responseCode === 200) {
        return response.result as object;
      } else {
        throw new APIError('添加评论失败', 'OPERATION_FAILED');
      }
    } catch (error) {
      console.error('[APIService] 添加评论失败:', error);
      if (error instanceof APIError) {
        throw error;
      }
      throw new APIError('添加评论请求失败', 'NETWORK_ERROR');
    }
  }
  
  /**
   * 获取用户收藏列表
   */
  public async fetchUserFavorites(): Promise<Array<object>> {
    try {
      if (!this._isLoggedIn) {
        throw new APIError('请先登录', 'NOT_LOGGED_IN');
      }
      
      const url = `${this.baseURL}/api/user/favorites`;
      const requestOptions = this.createRequestOptions(http.RequestMethod.GET);
      const response = await http.createHttp().request(url, requestOptions);
      
      if (response.responseCode === 200) {
        const result = response.result;
        
        // 策略1: 直接返回数组 (服务器直接返回数组的情况)
        if (Array.isArray(result)) {
          console.info('[APIService] fetchUserFavorites: 直接数组格式, count=' + result.length);
          return result;
        }
        
        // 策略2: APIResponse 包装格式 { data: [...] }
        const wrapped = result as APIResponse<Array<object>>;
        if (wrapped && Array.isArray(wrapped.data)) {
          console.info('[APIService] fetchUserFavorites: APIResponse包装格式, count=' + wrapped.data.length);
          return wrapped.data;
        }
        
        console.warn('[APIService] fetchUserFavorites: 未知响应格式', result);
        return [];
      } else {
        throw new APIError('获取收藏失败', 'FETCH_FAILED');
      }
    } catch (error) {
      console.error('[APIService] 获取收藏失败:', error);
      if (error instanceof APIError) {
        throw error;
      }
      throw new APIError('获取收藏请求失败', 'NETWORK_ERROR');
    }
  }
  
  /**
   * 获取用户创建的配方列表
   */
  public async fetchUserCreatedRecipes(): Promise<Array<object>> {
    try {
      if (!this._isLoggedIn) {
        throw new APIError('请先登录', 'NOT_LOGGED_IN');
      }
      
      const url = `${this.baseURL}/api/user/created-recipes`;
      const requestOptions = this.createRequestOptions(http.RequestMethod.GET);
      const response = await http.createHttp().request(url, requestOptions);
      
      if (response.responseCode === 200) {
        const result = response.result;
        
        // 策略1: 直接返回数组 (服务器直接返回数组的情况)
        if (Array.isArray(result)) {
          console.info('[APIService] fetchUserCreatedRecipes: 直接数组格式, count=' + result.length);
          return result;
        }
        
        // 策略2: APIResponse 包装格式 { data: [...] }
        const wrapped = result as APIResponse<Array<object>>;
        if (wrapped && Array.isArray(wrapped.data)) {
          console.info('[APIService] fetchUserCreatedRecipes: APIResponse包装格式, count=' + wrapped.data.length);
          return wrapped.data;
        }
        
        console.warn('[APIService] fetchUserCreatedRecipes: 未知响应格式', result);
        return [];
      } else {
        throw new APIError('获取配方失败', 'FETCH_FAILED');
      }
    } catch (error) {
      console.error('[APIService] 获取配方失败:', error);
      if (error instanceof APIError) {
        throw error;
      }
      throw new APIError('获取配方请求失败', 'NETWORK_ERROR');
    }
  }
  
  /**
   * 获取用户点赞列表
   */
  public async fetchUserLikes(): Promise<Array<object>> {
    try {
      if (!this._isLoggedIn) {
        throw new APIError('请先登录', 'NOT_LOGGED_IN');
      }
      
      const url = `${this.baseURL}/api/user/likes`;
      const requestOptions = this.createRequestOptions(http.RequestMethod.GET);
      const response = await http.createHttp().request(url, requestOptions);
      
      if (response.responseCode === 200) {
        const result = response.result;
        
        // 策略1: 直接返回数组
        if (Array.isArray(result)) {
          console.info('[APIService] fetchUserLikes: 直接数组格式, count=' + result.length);
          return result;
        }
        
        // 策略2: APIResponse 包装格式
        const wrapped = result as APIResponse<Array<object>>;
        if (wrapped && Array.isArray(wrapped.data)) {
          console.info('[APIService] fetchUserLikes: APIResponse包装格式, count=' + wrapped.data.length);
          return wrapped.data;
        }
        
        console.warn('[APIService] fetchUserLikes: 未知响应格式', result);
        return [];
      } else {
        throw new APIError('获取点赞失败', 'FETCH_FAILED');
      }
    } catch (error) {
      console.error('[APIService] 获取点赞失败:', error);
      if (error instanceof APIError) {
        throw error;
      }
      throw new APIError('获取点赞请求失败', 'NETWORK_ERROR');
    }
  }
  
  /**
   * 更新用户资料
   * @param nickname 昵称（可选）
   * @param bio 个人简介（可选）
   */
  public async updateUserProfile(nickname?: string, bio?: string): Promise<void> {
    try {
      if (!this._isLoggedIn) {
        throw new APIError('请先登录', 'NOT_LOGGED_IN');
      }
      
      // 当前资料，用于判断是否需要更新
      const currentNickname: string = this._currentUser && this._currentUser.username ? this._currentUser.username : '';
      const currentSignature: string = this._currentUser && this._currentUser.signature ? this._currentUser.signature : '';
      const newNickname: string | undefined = nickname !== undefined ? nickname.trim() : undefined;
      const newSignature: string | undefined = bio !== undefined ? bio.trim() : undefined;

      // 1) 昵称更新（PUT /api/user/profile）- 仅当变更时调用
      if (newNickname && newNickname.length > 0 && newNickname !== currentNickname) {
        interface UpdateProfileRequest { nickname: string; }
        const profileUrl = `${this.baseURL}/api/user/profile`;
        const profileBody: UpdateProfileRequest = { nickname: newNickname };
        const profileOptions = this.createRequestOptions(
          http.RequestMethod.PUT,
          { contentType: 'application/json' },
          profileBody
        );
        const profileResp = await http.createHttp().request(profileUrl, profileOptions);
        if (profileResp.responseCode !== 200) {
          // 后端可能返回 409（昵称已被使用）或其他错误
          let message = '更新昵称失败';
          try {
            const resObj: object = typeof profileResp.result === 'string' ? JSON.parse(profileResp.result) as object : profileResp.result as object;
            const msg: string = Reflect.get(resObj, 'message') as string;
            if (msg && msg.length > 0) { message = msg; }
          } catch (_) {}
          throw new APIError(message, 'UPDATE_NICKNAME_FAILED');
        }
      }

      // 2) 简介（签名）更新（POST /api/user/signature）- 仅当变更时调用
      if (newSignature !== undefined && newSignature !== currentSignature) {
        interface UpdateSignatureRequest { signature: string; }
        const signatureUrl = `${this.baseURL}/api/user/signature`;
        const signatureBody: UpdateSignatureRequest = { signature: newSignature };
        const signatureOptions = this.createRequestOptions(
          http.RequestMethod.POST,
          { contentType: 'application/json' },
          signatureBody
        );
        const signatureResp = await http.createHttp().request(signatureUrl, signatureOptions);
        if (signatureResp.responseCode !== 200) {
          let message = '更新简介失败';
          try {
            const resObj: object = typeof signatureResp.result === 'string' ? JSON.parse(signatureResp.result) as object : signatureResp.result as object;
            const msg: string = Reflect.get(resObj, 'message') as string;
            if (msg && msg.length > 0) { message = msg; }
          } catch (_) {}
          throw new APIError(message, 'UPDATE_SIGNATURE_FAILED');
        }
      }

      console.info('[APIService] 用户资料更新完成');
      this.notifyListeners();
    } catch (error) {
      console.error('[APIService] 更新用户资料失败:', error);
      if (error instanceof APIError) {
        throw error;
      }
      throw new APIError('更新用户资料请求失败', 'NETWORK_ERROR');
    }
  }

  /**
   * 单独更新用户签名（简介）
   */
  public async updateUserSignature(signature: string): Promise<void> {
    try {
      if (!this._isLoggedIn) {
        throw new APIError('请先登录', 'NOT_LOGGED_IN');
      }
      interface UpdateSignatureRequest { signature: string; }
      const url = `${this.baseURL}/api/user/signature`;
      const body: UpdateSignatureRequest = { signature: signature };
      const options = this.createRequestOptions(
        http.RequestMethod.POST,
        { contentType: 'application/json' },
        body
      );
      const resp = await http.createHttp().request(url, options);
      if (resp.responseCode !== 200) {
        let message = '更新简介失败';
        try {
          const resObj: object = typeof resp.result === 'string' ? JSON.parse(resp.result) as object : resp.result as object;
          const msg: string = Reflect.get(resObj, 'message') as string;
          if (msg && msg.length > 0) { message = msg; }
        } catch (_) {}
        throw new APIError(message, 'UPDATE_SIGNATURE_FAILED');
      }
      this.notifyListeners();
    } catch (error) {
      console.error('[APIService] 更新签名失败:', error);
      if (error instanceof APIError) { throw error; }
      throw new APIError('更新签名请求失败', 'NETWORK_ERROR');
    }
  }
  
  /**
   * 获取用户资料详情
   */
  public async fetchUserProfile(): Promise<object> {
    try {
      if (!this._isLoggedIn) {
        throw new APIError('请先登录', 'NOT_LOGGED_IN');
      }
      
      const url = `${this.baseURL}/api/user/profile`;
      const requestOptions = this.createRequestOptions(http.RequestMethod.GET);
      const response = await http.createHttp().request(url, requestOptions);
      
      if (response.responseCode === 200) {
        const result = response.result;
        console.info('[APIService] 获取用户资料成功');
        return result as object;
      } else {
        throw new APIError('获取用户资料失败', 'FETCH_FAILED');
      }
    } catch (error) {
      console.error('[APIService] 获取用户资料失败:', error);
      if (error instanceof APIError) {
        throw error;
      }
      throw new APIError('获取用户资料请求失败', 'NETWORK_ERROR');
    }
  }
  
  /**
   * 获取随机配方列表(用于推荐)
   * @param limit 数量限制
   */
  public async fetchRandomRecipes(limit: number = 100): Promise<Array<object>> {
    try {
      console.info(`[APIService] 获取随机配方, limit=${limit}`);
      // 使用sort=random获取随机排序的配方
      const response = await this.fetchRecipes(1, limit, '', 'random');
      
      // 类型安全的访问recipes属性
      const responseObj = response as RecipesResponse;
      if (responseObj && responseObj.recipes) {
        const recipes: Array<object> = responseObj.recipes;
        console.info(`[APIService] 获取到 ${recipes.length} 个随机配方`);
        return recipes;
      }
      
      console.warn('[APIService] fetchRandomRecipes: 响应格式异常');
      return [];
    } catch (error) {
      console.error('[APIService] 获取随机配方失败:', error);
      if (error instanceof Error) {
        throw error;
      }
      throw new APIError('获取随机配方失败', 'NETWORK_ERROR');
    }
  }
  
  // TODO: 添加更多API方法
  // - 创建配方
  // - 删除配方
  // - AI生成配方
  // - 管理员相关接口
  
  /**
   * 获取自定义配方的原料列表
   */
  public async fetchCustomIngredients(): Promise<object> {
    const httpRequest = http.createHttp();
    try {
      const url = `${this.baseURL}/api/custom/ingredients`;
      const requestOptions = this.createRequestOptions(http.RequestMethod.GET);
      const response = await httpRequest.request(url, requestOptions);
      
      if (response.responseCode === 200) {
        return response.result as object;
      } else {
        throw new APIError(`获取原料列表失败 (${response.responseCode})`, 'FETCH_FAILED');
      }
    } catch (error) {
      console.error('[APIService] 获取原料列表失败:', error);
      if (error instanceof APIError) {
        throw error;
      }
      throw new APIError('获取原料列表失败', 'NETWORK_ERROR');
    } finally {
      httpRequest.destroy();
    }
  }
  
  /**
   * 创建新配方
   */
  public async createRecipe(recipeData: object): Promise<object> {
    if (!this.isLoggedIn) {
      throw new APIError('请先登录', 'AUTH_REQUIRED');
    }

    const httpRequest = http.createHttp();
    try {
      // 与带图接口保持一致的自定义配方端点
      const url = `${this.baseURL}/api/custom/cocktails`;

      const name: string = Reflect.get(recipeData as ESObject, 'name') as string;
      const description: string = (Reflect.get(recipeData as ESObject, 'description') as string) || '';
      const estimatedAbvValue: ESObject = Reflect.get(recipeData as ESObject, 'estimatedAbv') as ESObject;
      const ingredientsValue: ESObject = Reflect.get(recipeData as ESObject, 'ingredients') as ESObject;
      const stepsValue: ESObject = Reflect.get(recipeData as ESObject, 'steps') as ESObject;
      const instructions: string = (Reflect.get(recipeData as ESObject, 'instructions') as string) || '';

      const body: UpdateRecipeRequestBody = {
        name: name,
        description: description,
        estimatedAbv: String(estimatedAbvValue),
        ingredients: JSON.stringify(ingredientsValue),
        steps: JSON.stringify(stepsValue || []),
        instructions: instructions
      };

      const requestOptions = this.createRequestOptions(
        http.RequestMethod.POST,
        { contentType: 'application/json' },
        body
      );
      requestOptions.connectTimeout = 60000;
      requestOptions.readTimeout = 60000;

      const response = await httpRequest.request(url, requestOptions);
      
      if (response.responseCode === 201 || response.responseCode === 200) {
        console.info('[APIService] 创建配方成功 (无图)');
        if (typeof response.result === 'string') {
          return JSON.parse(response.result) as object;
        }
        return response.result as object;
      }
      throw new APIError(`创建配方失败 (${response.responseCode})`, 'CREATE_FAILED');
    } catch (error) {
      console.error('[APIService] 创建配方失败:', error);
      if (error instanceof APIError) {
        throw error;
      }
      throw new APIError('创建配方失败', 'NETWORK_ERROR');
    } finally {
      httpRequest.destroy();
    }
  }

  // 更新配方（不带图片，JSON字段字符串化以兼容后端解析）
  public async updateRecipe(recipeId: string, recipeData: object): Promise<object> {
    try {
      const url = `${this.baseURL}/api/custom/cocktails/${recipeId}`;
      const name: string = Reflect.get(recipeData as ESObject, 'name') as string;
      const description: string = Reflect.get(recipeData as ESObject, 'description') as string;
      const estimatedAbvValue: ESObject = Reflect.get(recipeData as ESObject, 'estimatedAbv') as ESObject;
      const ingredientsValue: ESObject = Reflect.get(recipeData as ESObject, 'ingredients') as ESObject;
      const stepsValue: ESObject = Reflect.get(recipeData as ESObject, 'steps') as ESObject;
      const instructions: string = Reflect.get(recipeData as ESObject, 'instructions') as string;

      const body: UpdateRecipeRequestBody = {
        name: name,
        description: description || '',
        estimatedAbv: String(estimatedAbvValue),
        ingredients: JSON.stringify(ingredientsValue),
        steps: JSON.stringify(stepsValue || []),
        instructions: instructions || ''
      };

      const options = this.createRequestOptions(http.RequestMethod.PUT, { contentType: 'application/json' }, body);
      options.readTimeout = 60000;
      options.connectTimeout = 60000;
      const response = await http.createHttp().request(url, options);
      if (response.responseCode === 200) {
        return typeof response.result === 'string' ? JSON.parse(response.result) : response.result;
      }
      throw new APIError('更新配方失败');
    } catch (error) {
      if (error instanceof Error) {
        throw error;
      }
      throw new APIError('未知错误: ' + JSON.stringify(error));
    }
  }

  // 更新配方（带图片，multipart）
  public async updateRecipeWithImage(context: common.UIAbilityContext, recipeId: string, recipeData: object, imagePath: string, imageFileName: string): Promise<object> {
    try {
      // 直接命中后端为鸿蒙兼容的 POST 更新接口
      const url = `${this.baseURL}/api/custom/cocktails/${recipeId}/update`;
      const internalUri = `internal://cache/${imageFileName}`;
      console.info(`[APIService] 更新配方图片: absolute=${imagePath}, internal=${internalUri}`);

      const files: Array<request.File> = [{
        filename: imageFileName && imageFileName.length > 0 ? imageFileName : 'image.jpg',
        name: 'image',
        uri: internalUri,
        type: 'image/jpeg'
      }];

      const data: Array<request.RequestData> = [
        { name: 'name', value: Reflect.get(recipeData as ESObject, 'name') as string },
        { name: 'description', value: (Reflect.get(recipeData as ESObject, 'description') as string) || '' },
        { name: 'estimatedAbv', value: String(Reflect.get(recipeData as ESObject, 'estimatedAbv')) },
        { name: 'ingredients', value: JSON.stringify(Reflect.get(recipeData as ESObject, 'ingredients')) },
        { name: 'steps', value: JSON.stringify(Reflect.get(recipeData as ESObject, 'steps') || []) },
        { name: 'instructions', value: (Reflect.get(recipeData as ESObject, 'instructions') as string) || '' }
      ];

      const uploadConfig: request.UploadConfig = {
        url: url,
        header: { 'Cookie': this.authCookie },
        method: 'POST',
        files: files,
        data: data
      };

      const uploadTask = await request.uploadFile(context, uploadConfig);
      return await new Promise<object>((resolve, reject) => {
        uploadTask.on('complete', (taskStates: Array<request.TaskState>) => {
          const result: UploadResult = { success: true };
          resolve(result);
        });
        uploadTask.on('fail', (taskStates: Array<request.TaskState>) => {
          reject(new APIError('更新失败', 'UPLOAD_FAILED'));
        });
      });
    } catch (error) {
      if (error instanceof Error) {
        throw error;
      }
      throw new APIError('未知错误: ' + JSON.stringify(error));
    }
  }

  // 删除自定义配方（DELETE 优先，POST 兼容鸿蒙端点）
  public async deleteCustomRecipe(recipeId: string): Promise<boolean> {
    try {
      const deleteUrl = `${this.baseURL}/api/custom/cocktails/${recipeId}`;
      const deleteResp = await http.createHttp().request(deleteUrl, this.createRequestOptions(http.RequestMethod.DELETE));
      if (deleteResp.responseCode === 200) {
        return true;
      }

      // 兼容后端提供的 POST 删除接口
      const postUrl = `${this.baseURL}/api/custom/cocktails/${recipeId}/delete`;
      const postResp = await http.createHttp().request(postUrl, this.createRequestOptions(http.RequestMethod.POST));
      return postResp.responseCode === 200;
    } catch (error) {
      console.error('[APIService] 删除自定义配方失败:', error);
      return false;
    }
  }
  
  /**
   * 创建带图片的配方
   */
  public async createRecipeWithImage(context: common.UIAbilityContext, recipeData: object, imagePath: string, imageFileName: string): Promise<object> {
    if (!this.isLoggedIn) {
      throw new APIError('请先登录', 'AUTH_REQUIRED');
    }
    
    try {
      const url = `${this.baseURL}/api/custom/cocktails`;
      
      // 使用 internal://cache/ 协议路径
      const internalUri = `internal://cache/${imageFileName}`;
      console.info('[APIService] 绝对路径:', imagePath);
      console.info('[APIService] Internal URI:', internalUri);
      
      // 构建multipart/form-data
      const files: Array<request.File> = [{
        filename: 'image.jpg',
        name: 'image',
        uri: internalUri,
        type: 'image/jpeg'
      }];
      
      // 将recipeData字段转为FormData格式
      const data: Array<request.RequestData> = [
        { name: 'name', value: Reflect.get(recipeData, 'name') as string },
        { name: 'description', value: Reflect.get(recipeData, 'description') as string || '' },
        { name: 'estimatedAbv', value: String(Reflect.get(recipeData, 'estimatedAbv')) },
        { name: 'ingredients', value: JSON.stringify(Reflect.get(recipeData, 'ingredients')) },
        { name: 'steps', value: JSON.stringify(Reflect.get(recipeData, 'steps') || []) }
      ];
      
      const uploadConfig: request.UploadConfig = {
        url: url,
        header: { 'Cookie': this.authCookie },
        method: 'POST',
        files: files,
        data: data
      };
      
      const uploadTask = await request.uploadFile(context, uploadConfig);
      
      return new Promise<object>((resolve, reject) => {
        uploadTask.on('complete', (taskStates: Array<request.TaskState>) => {
          console.info('[APIService] 带图片创建配方成功');
          const result: UploadResult = { success: true };
          resolve(result);
        });
        
        uploadTask.on('fail', (taskStates: Array<request.TaskState>) => {
          console.error('[APIService] 带图片创建配方失败');
          reject(new APIError('上传失败', 'UPLOAD_FAILED'));
        });
      });
      
    } catch (error) {
      console.error('[APIService] 带图片创建配方失败:', error);
      if (error instanceof APIError) {
        throw error;
      }
      throw new APIError('创建配方失败', 'NETWORK_ERROR');
    }
  }
  
  /**
   * AI智能调酒师 - 根据口味描述生成配方
   * @param tasteDescription 口味描述
   * @param occasion 适用场合（可选）
   * @param alcoholStrength 酒精强度（可选）
   */
  public async generateAIRecipe(
    tasteDescription: string,
    occasion?: string,
    alcoholStrength?: string
  ): Promise<AIGeneratedRecipe> {
    const httpRequest = http.createHttp();
    try {
      const url = `${this.baseURL}/api/custom/generate-recipe`;
      
      const requestBody: AIRecipeRequest = {
        tasteDescription: tasteDescription
      };
      if (occasion && occasion.length > 0) {
        requestBody.occasion = occasion;
      }
      if (alcoholStrength && alcoholStrength.length > 0) {
        requestBody.alcoholStrength = alcoholStrength;
      }
      
      const requestOptions = this.createRequestOptions(
        http.RequestMethod.POST,
        { contentType: 'application/json' },
        requestBody
      );
      
      // 设置较长的超时时间，因为AI生成需要时间
      requestOptions.connectTimeout = 30000;
      requestOptions.readTimeout = 60000;
      
      console.info('[APIService] 正在调用AI生成配方...');
      const response = await httpRequest.request(url, requestOptions);
      
      if (response.responseCode === 200) {
        const result = response.result as object;
        console.info('[APIService] AI配方生成成功, result:', JSON.stringify(result));
        
        // 服务端返回格式: { success: true, recipe: {...}, generatedAt: ... }
        const recipeData = Reflect.get(result, 'recipe') as AIGeneratedRecipe;
        if (recipeData) {
          return recipeData;
        }
        
        // 兼容直接返回配方的情况
        if (Reflect.has(result, 'name') && Reflect.has(result, 'ingredients')) {
          return result as AIGeneratedRecipe;
        }
        
        throw new APIError('AI返回数据格式错误', 'PARSE_ERROR');
      } else {
        const errorResult = response.result as object;
        const message = Reflect.get(errorResult, 'message') as string;
        throw new APIError(message || 'AI生成配方失败', 'AI_GENERATE_FAILED');
      }
    } catch (error) {
      console.error('[APIService] AI生成配方失败:', error);
      if (error instanceof APIError) {
        throw error;
      }
      throw new APIError('AI生成配方请求失败，请稍后重试', 'NETWORK_ERROR');
    } finally {
      httpRequest.destroy();
    }
  }

  /**
   * 获取配方评分信息
   */
  async fetchRecipeRatings(recipeId: string): Promise<RecipeRatingResponse> {
    const httpRequest = http.createHttp();
    const url = `${this.baseURL}/api/recipes/${recipeId}/ratings`;
    
    try {
      const requestOptions = this.createRequestOptions(http.RequestMethod.GET);
      console.info(`[APIService] 获取AI分析数据, URL: ${url}`);
      const response = await httpRequest.request(url, requestOptions);
      
      if (response.responseCode === 200) {
        let result: object;
        if (typeof response.result === 'string') {
          result = JSON.parse(response.result) as object;
        } else {
          result = response.result as object;
        }
        
        const aiAnalysis = Reflect.get(result, 'aiAnalysis') as string | undefined;
        console.info(`[APIService] AI分析数据: ${aiAnalysis ? '已找到' : '无数据'}`);
        
        return {
          success: true,
          hasRating: Reflect.get(result, 'hasRating') as boolean,
          ratings: Reflect.get(result, 'ratings') as RecipeScores | undefined,
          calculatedScore: Reflect.get(result, 'calculatedScore') as number | undefined,
          aiAnalysis: aiAnalysis,
          ratedAt: Reflect.get(result, 'ratedAt') as string | undefined
        };
      }
      throw new APIError('获取评分失败', 'FETCH_RATINGS_FAILED');
    } catch (error) {
      console.error('[APIService] 获取评分失败:', error);
      if (error instanceof APIError) {
        throw error;
      }
      throw new APIError('获取评分请求失败', 'NETWORK_ERROR');
    } finally {
      httpRequest.destroy();
    }
  }

  /**
   * 保存配方评分
   */
  async saveRecipeRatings(recipeId: string, scores: RecipeScores, aiAnalysis?: string): Promise<object> {
    const httpRequest = http.createHttp();
    const url = `${this.baseURL}/api/recipes/${recipeId}/ratings`;
    
    try {
      const requestBody: SaveRatingsRequest = { scores: scores, aiAnalysis: aiAnalysis };
      const requestOptions = this.createRequestOptions(
        http.RequestMethod.POST,
        { contentType: 'application/json' },
        requestBody
      );
      const response = await httpRequest.request(url, requestOptions);
      
      if (response.responseCode === 200) {
        return response.result as object;
      }
      const errorResult = response.result as object;
      const message = Reflect.get(errorResult, 'message') as string;
      throw new APIError(message || '保存评分失败', 'SAVE_RATINGS_FAILED');
    } catch (error) {
      console.error('[APIService] 保存评分失败:', error);
      if (error instanceof APIError) {
        throw error;
      }
      throw new APIError('保存评分请求失败', 'NETWORK_ERROR');
    } finally {
      httpRequest.destroy();
    }
  }

  /**
   * AI口味分析
   */
  async analyzeRecipeFlavor(recipeId: string): Promise<AIAnalysisResponse> {
    // 首先获取配方详情
    const recipeDetail = await this.fetchRecipeDetail(recipeId);
    
    const httpRequest = http.createHttp();
    const url = `${this.baseURL}/api/custom/analyze-flavor`;
    
    try {
      // 从配方详情中提取数据
      const name = Reflect.get(recipeDetail, 'name') as string || '';
      const description = Reflect.get(recipeDetail, 'description') as string || '';
      const ingredients = Reflect.get(recipeDetail, 'ingredients') as Array<object> || [];
      const instructions = Reflect.get(recipeDetail, 'instructions') as string || '';
      const steps = instructions ? instructions.split('\n') : [];
      
      // 构建请求体
      const requestBody: AIAnalyzeRequest = {
        name: name,
        description: description,
        ingredients: ingredients,
        steps: steps
      };
      
      const requestOptions = this.createRequestOptions(
        http.RequestMethod.POST,
        { contentType: 'application/json' },
        requestBody
      );
      requestOptions.connectTimeout = 30000;
      requestOptions.readTimeout = 60000;
      
      console.info(`[APIService] 正在进行AI口味分析, URL: ${url}`);
      const response = await httpRequest.request(url, requestOptions);
      
      console.info(`[APIService] AI分析响应码: ${response.responseCode}`);
      
      if (response.responseCode === 200) {
        let result: object;
        if (typeof response.result === 'string') {
          result = JSON.parse(response.result) as object;
        } else {
          result = response.result as object;
        }
        return {
          success: true,
          analysis: Reflect.get(result, 'analysis') as string,
          analyzedAt: Reflect.get(result, 'analyzedAt') as string
        };
      }
      
      // 解析错误响应
      let errorMessage = 'AI分析失败';
      try {
        let errorResult: object;
        if (typeof response.result === 'string') {
          errorResult = JSON.parse(response.result) as object;
        } else {
          errorResult = response.result as object;
        }
        const msg = Reflect.get(errorResult, 'message') as string;
        if (msg) {
          errorMessage = msg;
        }
      } catch (parseError) {
        console.error('[APIService] 解析错误响应失败:', parseError);
      }
      console.error(`[APIService] AI分析失败: ${errorMessage}`);
      throw new APIError(errorMessage, 'AI_ANALYZE_FAILED');
    } catch (error) {
      console.error('[APIService] AI分析请求异常:', error);
      if (error instanceof APIError) {
        throw error;
      }
      const errMsg = error instanceof Error ? error.message : 'AI分析服务暂时不可用';
      throw new APIError(errMsg, 'AI_SERVICE_ERROR');
    } finally {
      httpRequest.destroy();
    }
  }
  
  public getFullImageUrl(relativePath: string | undefined): string {
    if (!relativePath) {
      return '';
    }
    if (relativePath.startsWith('http')) {
      return relativePath;
    }
    const base = this.baseURL.endsWith('/') ? this.baseURL.slice(0, -1) : this.baseURL;
    const path = relativePath.startsWith('/') ? relativePath : '/' + relativePath;
    return `${base}${path}`;
  }
  
  public async fetchCurrentUser(): Promise<User> {
    try {
      if (!this._isLoggedIn) {
        throw new APIError('未登录', 'NOT_LOGGED_IN');
      }

      const url = `${this.baseURL}/api/user/current`;
      const requestOptions = this.createRequestOptions(http.RequestMethod.GET);
      const response = await http.createHttp().request(url, requestOptions);

      if (response.responseCode === 200) {
        const userData = response.result as User;
        this._currentUser = userData;
        this.updateLoginState(true, userData);
        return userData;
      } else {
        throw new APIError('获取用户信息失败', 'FETCH_FAILED');
      }
    } catch (error) {
      console.error('[APIService] fetchCurrentUser failed:', error);
      if (error instanceof APIError) {
        throw error;
      } else if (error instanceof Error) {
        throw error;
      } else {
        throw new APIError('获取用户信息发生未知错误', 'UNKNOWN');
      }
    }
  }
  
  public async uploadAvatar(context: common.UIAbilityContext, filePath: string): Promise<boolean> {
    return new Promise(async (resolve, reject) => {
      try {
        if (!this._isLoggedIn) {
          reject(new APIError('未登录', 'NOT_LOGGED_IN'));
          return;
        }

        console.info(`[Upload Monitor] 开始上传头像... 本地路径: ${filePath}`);

        let uploadConfig: request.UploadConfig = {
          url: `${this.baseURL}/api/user/avatar`,
          header: {
            'Cookie': this.authCookie,
            'Content-Type': 'multipart/form-data'
          },
          method: 'POST',
          files: [{
            filename: 'avatar.jpg',
            name: 'avatar',
            uri: `internal://cache/${filePath.split('/').pop()}`,
            type: 'image/jpeg'
          }],
          data: []
        };

        const uploadTask = await request.uploadFile(context, uploadConfig);

        uploadTask.on('complete', (taskStates) => {
          this.fetchCurrentUser().then((updatedUser) => {
            console.info('========== [Upload Monitor] 上传成功报告 ==========');
            console.info(`[Monitor] 用户名: ${updatedUser.username}`);
            console.info(`[Monitor] 原始Avatar字段: ${updatedUser.avatar}`);
            console.info(`[Monitor] 最终显示URL: ${this.getFullImageUrl(updatedUser.avatar)}`);
            console.info('===================================================');
            resolve(true);
          }).catch((err: Error) => {
            console.warn(`[Upload Monitor] 文件上传成功，但刷新用户信息失败: ${JSON.stringify(err)}`);
            resolve(true);
          });
        });

        uploadTask.on('fail', (taskStates) => {
          console.error('[Upload Monitor] ❌ 上传失败:', JSON.stringify(taskStates));
          reject(new APIError('上传失败', 'UPLOAD_FAILED'));
        });

      } catch (error) {
        console.error('[Upload Monitor] 创建上传任务出错:', error);
        reject(error);
      }
    });
  }
  
  public async put(path: string, data: object): Promise<object> {
    if (!this.isLoggedIn) {
      throw new APIError('请先登录', 'AUTH_REQUIRED');
    }

    const httpRequest = http.createHttp();
    try {
      const url = `${this.baseURL}${path}`;
      const requestOptions = this.createRequestOptions(
        http.RequestMethod.PUT,
        { contentType: 'application/json' },
        data
      );

      console.info(`[APIService] 正在发送 PUT 请求至: ${url}`);
      const response = await httpRequest.request(url, requestOptions);

      if (response.responseCode === 200 || response.responseCode === 204) {
        console.info('[APIService] 数据更新成功');
        return response.result as object;
      } else {
        throw new APIError(`更新失败 (状态码: ${response.responseCode})`, 'UPDATE_FAILED');
      }
    } catch (error) {
      console.error('[APIService] PUT 请求异常:', error);
      if (error instanceof APIError) throw error;
      throw new APIError('服务器更新请求失败', 'NETWORK_ERROR');
    } finally {
      httpRequest.destroy();
    }
  }
  
  public async getAdminStats(): Promise<AdminStats> {
    console.info('>>> 正在调用 getAdminStats...');
    try {
      const url = `${this.baseURL}/api/admin/stats`;
      const requestOptions = this.createRequestOptions(http.RequestMethod.GET);
      const response = await http.createHttp().request(url, requestOptions);

      console.info('远程服务器返回:', JSON.stringify(response.result));

      if (response.responseCode === 200) {
        return response.result as AdminStats;
      }
      throw new APIError('获取统计数据失败');
    } catch (error) {
      if (error instanceof Error) { throw error; }
      else { throw new APIError('未知错误: ' + JSON.stringify(error)); }
    }
  }

  public async getAllUsers(): Promise<User[]> {
    try {
      const url = `${this.baseURL}/api/admin/users?limit=100`;
      const requestOptions = this.createRequestOptions(http.RequestMethod.GET);
      const response = await http.createHttp().request(url, requestOptions);

      if (response.responseCode === 200) {
        const res: AdminUsersResponse = (typeof response.result === 'string' ? JSON.parse(response.result) : response.result) as AdminUsersResponse;
        console.info('[APIService] Admin用户列表原始数据:', JSON.stringify(res.users[0]));
        if (res.users && Array.isArray(res.users)) {
          return res.users;
        }
        return [];
      }
      throw new APIError('获取用户列表失败');
    } catch (error) {
      if (error instanceof Error) {
        throw error;
      } else {
        throw new APIError('未知错误: ' + JSON.stringify(error));
      }
    }
  }

  public async deleteUser(userId: string): Promise<boolean> {
    try {
      const url = `${this.baseURL}/api/admin/users/${userId}`;
      const requestOptions = this.createRequestOptions(http.RequestMethod.DELETE);
      const response = await http.createHttp().request(url, requestOptions);

      return response.responseCode === 200;
    } catch (error) {
      console.error('Delete user failed:', error);
      return false;
    }
  }

  public async getAllRecipesForAdmin(): Promise<AdminRecipe[]> {
    try {
      const url = `${this.baseURL}/api/recipes?limit=100`;
      const requestOptions = this.createRequestOptions(http.RequestMethod.GET);
      const response = await http.createHttp().request(url, requestOptions);

      if (response.responseCode === 200) {
        const res = (typeof response.result === 'string' ? JSON.parse(response.result) : response.result) as AdminRecipesResponse;

        if (res.recipes && Array.isArray(res.recipes)) {
          return res.recipes;
        }
        return [];
      }
      throw new APIError('获取配方列表失败');
    } catch (error) {
      if (error instanceof Error) {
        throw error;
      } else {
        throw new APIError('未知错误: ' + JSON.stringify(error));
      }
    }
  }

  public async deleteRecipe(recipeId: string): Promise<boolean> {
    try {
      const url = `${this.baseURL}/api/recipes/${recipeId}`;
      const requestOptions = this.createRequestOptions(http.RequestMethod.DELETE);
      const response = await http.createHttp().request(url, requestOptions);

      return response.responseCode === 200;
    } catch (error) {
      console.error('Delete recipe failed:', error);
      return false;
    }
  }
  
  public async getAdminComments(): Promise<AdminComment[]> {
    try {
      const url = `${this.baseURL}/api/admin/comments?limit=100`;
      const response = await http.createHttp().request(url, this.createRequestOptions(http.RequestMethod.GET));

      if (response.responseCode === 200) {
        const res = (typeof response.result === 'string' ? JSON.parse(response.result) : response.result) as AdminCommentsResponse;

        if (res.comments && Array.isArray(res.comments)) {
          return res.comments;
        }
        return [];
      }
      return [];
    } catch (error) {
      return [];
    }
  }

  public async deleteComment(commentId: string): Promise<boolean> {
    try {
      const url = `${this.baseURL}/api/comments/${commentId}`;
      const response = await http.createHttp().request(url, this.createRequestOptions(http.RequestMethod.DELETE));
      return response.responseCode === 200;
    } catch (e) { return false; }
  }

  // ==================== 二级缓存管理方法 ====================

  /**
   * 清空推荐缓存
   */
  public async clearRecommendationCache(): Promise<void> {
    await this.recommendationCache.clear();
    await this.userPreferencesCache.clear();
    console.info('[APIService] 推荐缓存已清空');
  }

  /**
   * 获取缓存统计信息
   */
  public getCacheStats(): ESObject {
    return {
      recommendation: this.recommendationCache.getStats(),
      userPreferences: this.userPreferencesCache.getStats()
    };
  }

  /**
   * 删除特定推荐缓存
   */
  public async deleteRecommendationCache(page: number, limit: number): Promise<void> {
    const cacheKey = `recommendations_${page}_${limit}_${this._currentUser?.username || 'anonymous'}`;
    await this.recommendationCache.delete(cacheKey);
  }

  /**
   * 删除用户偏好缓存
   */
  public async deleteUserPreferencesCache(): Promise<void> {
    const preferencesCacheKey = `user_prefs_${this._currentUser?.username || 'anonymous'}`;
    await this.userPreferencesCache.delete(preferencesCacheKey);
  }

  /**
   * 预热缓存 - 为常用页面预先加载推荐
   */
  public async warmupRecommendationCache(): Promise<void> {
    console.info('[APIService] 开始预热推荐缓存...');
    
    try {
      // 预热前3页推荐
      for (let page = 1; page <= 3; page++) {
        await this.fetchRecommendationsWithCache(page, 10, false);
      }
      console.info('[APIService] 推荐缓存预热完成');
    } catch (error) {
      console.error('[APIService] 推荐缓存预热失败:', error);
    }
  }

  /**
   * 重置推荐会话（兼容原有方法，同时清空缓存）
   */
  public resetRecommendationSession(): void {
    this.recommendationSessionCache = [];
    this.recommendationSessionSeed = Date.now();
    
    // 同时清空二级缓存
    this.clearRecommendationCache();
    
    console.info('[APIService] 推荐会话已重置，将重新随机分层抽取');
  }
}

// 评分响应接口
export interface RecipeRatingResponse {
  success: boolean;
  hasRating: boolean;
  ratings?: RecipeScores;
  calculatedScore?: number;
  aiAnalysis?: string;
  ratedAt?: string;
}

// 评分数据接口
export interface RecipeScores {
  visual: number;      // 外观 (0-10)
  aroma: number;       // 香气 (0-10)
  taste: number;       // 风味 (0-10)
  mouthfeel: number;   // 口感 (0-10)
  finish: number;      // 余韵 (0-10)
}

// AI分析响应接口
export interface AIAnalysisResponse {
  success: boolean;
  analysis: string;
  analyzedAt: string;
}

// 保存评分请求体接口
interface SaveRatingsRequest {
  scores: RecipeScores;
  aiAnalysis?: string;
}

// 空请求体接口
interface EmptyRequest {
  placeholder?: string;
}

// AI分析请求体接口
interface AIAnalyzeRequest {
  name: string;
  description: string;
  ingredients: Array<object>;
  steps: Array<string>;
}

// AI配方请求接口
interface AIRecipeRequest {
  tasteDescription: string;
  occasion?: string;
  alcoholStrength?: string;
}

// AI生成的配方接口
export interface AIGeneratedRecipe {
  name: string;
  description: string;
  ingredients: AIIngredient[];
  steps: string[];
  glassware?: string;
  garnish?: string;
  taste_profile?: TasteProfile;
  tips?: string;
  isDemo?: boolean;
}

// AI配方中的配料接口
export interface AIIngredient {
  name: string;
  volume: number;
  abv: number;
  category?: string;
}

// 口味配置接口
interface TasteProfile {
  sweetness: string;
  sourness: string;
  bitterness: string;
  strength: string;
}

// 导出单例实例
export const apiService = APIService.getInstance();
