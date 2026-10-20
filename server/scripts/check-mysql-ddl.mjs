import { dialectFor, uniqueIndexes } from '../src/db/dialect.js';
import { TABLES, INDEXES } from '../src/db/schema.js';

const d = dialectFor('mysql');
let problems = 0;
console.log('=== MySQL DDL 静态检查 ===\n');
for (const [name, ddl] of Object.entries(TABLES)) {
  const sql = ddl(d);
  const issues = [];
  // SQLite 专有语法不应出现在 MySQL 分支
  if (/AUTOINCREMENT/i.test(sql)) issues.push('含 SQLite 专有 AUTOINCREMENT');
  if (/TEXT \/\*/.test(sql)) issues.push('含 SQLite 注释残留');
  if (/TEXT NOT NULL/i.test(sql) && !/VARCHAR/.test(sql)) issues.push('TEXT 列无默认值可能报错(MySQL)');
  if (/,\s*\)/.test(sql)) issues.push('尾随逗号');
  // 表内 UNIQUE 不应出现（改用独立索引）
  if (/UNIQUE\s*\(/i.test(sql)) issues.push('表内 UNIQUE 子句');
  if (issues.length) { problems += issues.length; console.log(`FAIL ${name}: ${issues.join('; ')}`); }
  else console.log(`ok   ${name}`);
}
console.log(`\n独立索引 ${uniqueIndexes().length + INDEXES.length} 条`);
console.log('（MySQL 不支持 CREATE INDEX IF NOT EXISTS —— 需确认迁移行为）');
console.log(`\n静态检查问题数: ${problems}`);
