/**
 * 本机收藏（方案 §7.3）。
 *
 * ## 方案明确规定的边界
 *
 * > 本机收藏 | `localStorage`（键 `fav.activities`）；UI 明示"仅保存在本机浏览器"
 *
 * > **明确不做**：账号级收藏、跨设备同步、服务端保存浏览记录。
 *
 * 因此这里只碰 `localStorage`，**不发任何请求**。
 * 「不做到服务端」这件事有实际意义：Web 端是公开只读的、没有账号，
 * 如果收藏要上传，就必须引入某种标识来区分用户 ——
 * 那等于在没有账号的架构里偷偷建了一套追踪机制。
 *
 * ## 存 id 还是存整个对象
 *
 * 只存 **id + 收藏时间**，不存活动快照。理由：
 *   * 活动信息会变（时间改期、取消），存快照会让收藏列表显示过期信息；
 *   * 快照会随活动数量线性增长，而 localStorage 只有约 5MB。
 *
 * 代价是"我的收藏"页需要按 id 去查服务端。这是对的：
 * 收藏列表应当显示**当前**的活动状态。
 */

const STORAGE_KEY = 'fav.activities';

/**
 * 读取收藏集合。
 *
 * 解析失败一律当作空集合，而不是抛异常 ——
 * localStorage 里的内容可能被用户手工改过、被其他版本写过、
 * 或者被浏览器清理成了半截。为了一个收藏功能让整页崩掉不值得。
 */
export function loadFavorites() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) {
      return {};
    }
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      // 过滤掉值不是对象的脏数据。
      const clean = {};
      for (const [k, v] of Object.entries(parsed)) {
        if (v && typeof v === 'object' && typeof v.at === 'string') {
          clean[k] = v;
        }
      }
      return clean;
    }
    return {};
  } catch {
    return {};
  }
}

/** 写入收藏集合。配额满或被禁用时静默失败（但保留内存状态）。 */
export function saveFavorites(map) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(map));
    return true;
  } catch (e) {
    /*
      两种失败是正常的，不该打扰用户：
        * QuotaExceededError：配额满（收藏了几千条）
        * Safari 隐私模式下 localStorage 直接抛异常
      但也不能完全不管 —— 至少要能在控制台看到。
    */
    // eslint-disable-next-line no-console
    console.warn('[收藏] 无法写入本机存储', e);
    return false;
  }
}

/**
 * 收藏状态管理（响应式）。
 *
 * 用模块级单例：收藏状态被列表页、收藏页、详情抽屉共享，
 * 各自维护一份必然不同步。
 *
 * ## ⚠️ 为什么必须提供 `reload()`
 *
 * 模块级 `favorites` 在**首次 import 时**读一次 localStorage，
 * 之后只由本模块的写入更新。这留下一个真实缺口：
 *
 *   * 用户在**另一个标签页**收藏了活动 → 本标签页不知道；
 *   * 或者 localStorage 被其它代码/手动修改（测试、调试）；
 *   * 或者浏览器从 bfcache 恢复页面时用了旧的内存状态。
 *
 * 表现是"收藏了但收藏页是空的"，而数据其实好好地在 localStorage 里。
 *
 * 处置：把"读"变成可重复的动作。进入收藏页时先 `reload()`，
 * 保证显示的是**存储里的真实内容**而不是内存里的旧快照。
 */

import { ref, computed } from 'vue';

const favorites = ref(loadFavorites());

export function useFavorites() {
  /** 是否已收藏。 */
  function isFavorite(id) {
    return Boolean(favorites.value[id]);
  }

  /** 切换收藏。返回切换后的状态。 */
  function toggle(activity) {
    const id = String(activity.id);
    const next = { ...favorites.value };
    if (next[id]) {
      delete next[id];
    } else {
      next[id] = {
        // 只存 id 与收藏时间，见文件头说明。
        id,
        at: new Date().toISOString(),
        /*
          顺带存标题：仅为在存储读取失败或活动已过期时，
          还能给用户一个可读的提示。**不用于展示活动状态** ——
          状态永远以服务端为准。
        */
        title: activity.title ?? '',
      };
    }
    favorites.value = next;
    saveFavorites(next);
    return Boolean(next[id]);
  }

  /** 清空收藏。 */
  function clear() {
    favorites.value = {};
    saveFavorites({});
  }

  /**
   * 重新从 localStorage 读取。
   *
   * 进入收藏页、或从后台切回前台时调用，避免显示内存里的旧快照。
   * 详见文件头关于"为什么必须提供 reload"的说明。
   */
  function reload() {
    favorites.value = loadFavorites();
    return favorites.value;
  }

  const count = computed(() => Object.keys(favorites.value).length);

  /** 收藏的 id 列表，按收藏时间倒序（最近收藏的先看到）。 */
  const ids = computed(() =>
    Object.values(favorites.value)
      .sort((a, b) => String(b.at).localeCompare(String(a.at)))
      .map((f) => f.id),
  );

  return { favorites, isFavorite, toggle, clear, reload, count, ids };
}

export { STORAGE_KEY };
