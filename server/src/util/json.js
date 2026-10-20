/**
 * JSON 字段的读写 —— 统一处理"库里是 TEXT、代码里是对象"。
 *
 * 单独成文件的原因：这类转换最容易写出两种不一致的写法
 * （一处 `JSON.parse`、一处直接当对象用），然后在某个字段为
 * `null` 或旧数据格式不对时炸掉。
 */

/**
 * 安全解析 JSON 文本。
 *
 * 解析失败返回 `fallback` 而**不抛异常**：库里的历史数据可能
 * 是早期版本写的、格式已经变了。为了读一条旧数据把整个列表接口
 * 打挂是不合理的 —— 降级成默认值，接口继续工作。
 */
export function parseJson(text, fallback = null) {
  if (text == null || text === '') {
    return fallback;
  }
  if (typeof text === 'object') {
    // MySQL 的 JSON 列驱动可能已经解析好了。
    return text;
  }
  try {
    return JSON.parse(String(text));
  } catch {
    return fallback;
  }
}

/** 解析成数组；不是数组时返回空数组。 */
export function parseJsonArray(text) {
  const v = parseJson(text, []);
  return Array.isArray(v) ? v : [];
}

/** 解析成对象；不是对象时返回 `null`。 */
export function parseJsonObject(text) {
  const v = parseJson(text, null);
  return v && typeof v === 'object' && !Array.isArray(v) ? v : null;
}

/** 序列化为 JSON 文本（用于写库）；`null` 写为 `null`。 */
export function toJsonText(value) {
  if (value == null) {
    return null;
  }
  return JSON.stringify(value);
}

/** 逗号分隔文本 → 字符串数组（标签用）。 */
export function parseCsv(text) {
  if (text == null || text === '') {
    return [];
  }
  return String(text)
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}
