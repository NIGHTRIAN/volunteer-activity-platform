/**
 * 逐表建表，定位失败的那一张。
 * 用法：node scripts/test-ddl-each.mjs
 */
import { createRequire } from 'node:module';
import { dialectFor } from '../src/db/dialect.js';
import { TABLES } from '../src/db/schema.js';

const require = createRequire(import.meta.url);
const { DatabaseSync } = require('node:sqlite');
const d = dialectFor('sqlite');

let failed = 0;
for (const [name, ddl] of Object.entries(TABLES)) {
  // 每张表用独立的内存库，互不影响。
  const db = new DatabaseSync(':memory:');
  try {
    db.exec(ddl(d));
    console.log(`ok    ${name}`);
  } catch (e) {
    failed += 1;
    console.log(`FAIL  ${name} -> ${e.message}`);
    console.log('----- 生成的 DDL -----');
    console.log(ddl(d).trim());
    console.log('----------------------');
  } finally {
    db.close();
  }
}
console.log(`\n失败 ${failed} 张`);
process.exit(failed > 0 ? 1 : 0);
