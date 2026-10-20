/**
 * 契约门面。
 *
 * ## 为什么要有这一层
 *
 * `contract/` 在仓库根（三端共用），而 `server/` 在它下面。
 * 于是 `src/xxx/yyy.js` 里 import 它需要写 `'../../../contract/constants.js'`
 * —— **层数随手一错就是一个运行时模块找不到**，而且直到真的 import
 * 到那个文件才暴露。
 *
 * 本项目已经在同一个坑里摔了两次（`http/envelope.js`、`seed/demo.js`）。
 * 与其逐个修，不如让**所有服务端代码只从这个文件取契约**：
 *
 *   ```js
 *   import { ERROR_CODES, ACTIVITY_STATUS } from '../contract.js';
 *   ```
 *
 * 相对路径的层数取决于当前文件在 `src/` 下的深度，而
 * `src/contract.js` 相对 `src/anything/` 永远是 `'../contract.js'`
 * 或 `'../../contract.js'` —— 但**测试与脚本**也能用同样的路径，
 * 因为它们都在 `server/` 下，统一写 `'../src/contract.js'` 即可。
 *
 * ## 顺带的好处
 *
 * 导出集中在这里，等于给"服务端用到了契约里的哪些东西"列了张清单。
 * 将来契约变更时，改动面一眼可见。
 */

export {
  // 信封与错误码
  ENVELOPE_FIELDS,
  ERROR_CODES,
  LOCAL_ERROR_CODES,
  errorFamilies,

  // 分页与头部
  PAGING,
  PAGE_DEFAULT_SIZE,
  PAGE_MAX_SIZE,
  HEADERS,

  // 枚举
  ACTIVITY_STATUS,
  TERMINAL_STATUSES,
  STATUS_TRANSITIONS,
  SIGNUP_STATUS,
  PARTICIPANT_CHECKIN_STATUS,
  CHECKIN_STATUS,
  CHECKIN_METHOD,
  ATTENDANCE_MODE,
  ATTENDANCE_TASK_STATUS,
  ATTENDANCE_SUMMARY,

  // 默认值与边界
  DEFAULTS,

  // 文案
  DISCLAIMER,
} from '../../contract/constants.js';
