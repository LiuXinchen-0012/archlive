#!/usr/bin/env node
// 校验所有 Calamares .conf / settings.conf 的 YAML 语法与关键字段
// 需要：npm i js-yaml
const yaml = require('js-yaml');
const fs = require('fs');
const path = require('path');

const ROOT = process.argv[2] || '/workspace/output/archlive/airootfs/etc/calamares';
let fail = 0;

function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(e => {
    const p = path.join(dir, e.name);
    return e.isDirectory() ? walk(p) : (/\.(conf|desc)$/.test(e.name) ? [p] : []);
  });
}

const files = walk(ROOT).sort();
if (!files.length) { console.log('  没有找到 .conf 文件'); process.exit(0); }

for (const f of files) {
  const rel = f.replace(ROOT + '/', '');
  const raw = fs.readFileSync(f, 'utf8');
  try {
    const d = yaml.load(raw);
    if (d === null || d === undefined) {
      console.log(`  \x1b[31mFAIL\x1b[0m    ${rel}  (解析为空)`); fail++; continue;
    }
    const keys = d && typeof d === 'object' ? Object.keys(d) : [];
    console.log(`  \x1b[32mok\x1b[0m      ${rel.padEnd(36)} ${JSON.stringify(keys).slice(0, 70)}`);
  } catch (e) {
    console.log(`  \x1b[31mFAIL\x1b[0m    ${rel}\n          ${String(e.message).split('\n')[0]}`);
    fail++;
  }
}

// settings.conf 的 sequence 交叉检查
console.log('\n== sequence 检查 ==');
const sp = path.join(ROOT, 'settings.conf');
if (fs.existsSync(sp)) {
  const s = yaml.load(fs.readFileSync(sp, 'utf8'));
  const all = (s && s.sequence) || [];
  const mods = new Set();
  for (const step of all) {
    if (typeof step === 'object' && step.show) step.show.forEach(m => mods.add(m));
    else if (typeof step === 'object' && step.exec) step.exec.forEach(m => mods.add(m));
    else mods.add(String(step));
  }
  console.log(`  引用的模块 (${mods.size}): ${[...mods].sort().join(', ')}`);

  // 每个模块都应该有对应的 conf 或属于内建
  const BUILTIN = new Set(['welcome','finished','summary','notesqml','license','hostinfo',
    'luksbootkeyfile','luksopenswaphookcfg','preservefiles','preexec','postexec']);
  for (const m of [...mods].sort()) {
    if (BUILTIN.has(m)) { console.log(`  \x1b[32mok\x1b[0m      ${m} (内建)`); continue; }
    const p = path.join(ROOT, 'modules', m + '.conf');
    if (fs.existsSync(p)) console.log(`  \x1b[32mok\x1b[0m      ${m} -> modules/${m}.conf`);
    else { console.log(`  \x1b[33mWARN\x1b[0m    ${m} 没有对应的 .conf（将用 Calamares 默认值）`); }
  }

  // 已知会被官方 AUR 包编译掉的模块
  const SKIPPED_BY_AUR = ['packagechooser','initramfs','interactiveterminal','dracut','services-openrc'];
  for (const m of mods) {
    if (SKIPPED_BY_AUR.includes(m)) {
      console.log(`  \x1b[33m注意\x1b[0m    ${m} 在官方 AUR 包里被 SKIP —— 我们已改 PKGBUILD 解开，需确认编译时生效`);
    }
  }

  // plasmalnf 已移除
  if (mods.has('plasmalnf')) {
    console.log('  \x1b[31mFAIL\x1b[0m    sequence 里还有 plasmalnf（本方案不需要 Plasma 主题模块）');
    fail++;
  } else {
    console.log('  \x1b[32mok\x1b[0m      plasmalnf 已移除');
  }

  // 代理相关必须排在 post-install 之前
  const execOrder = [];
  for (const step of all) if (step && step.exec) execOrder.push(...step.exec);
  const iLive = execOrder.indexOf('shellprocess-live-proxy');
  const iPost = execOrder.indexOf('shellprocess-postinstall');
  if (iLive >= 0 && iPost >= 0) {
    if (iLive < iPost) console.log('  \x1b[32mok\x1b[0m      代理配置排在 post-install 之前（时序正确）');
    else { console.log('  \x1b[31mFAIL\x1b[0m    代理配置必须排在 post-install 之前'); fail++; }
  } else {
    console.log('  \x1b[33mWARN\x1b[0m    没找到代理/post-install 步骤，检查 sequence');
  }

  // 每个 shellprocess 必须 dontChroot
  for (const f of fs.readdirSync(path.join(ROOT, 'modules'))) {
    if (!f.startsWith('shellprocess-')) continue;
    const p = path.join(ROOT, 'modules', f);
    const c = yaml.load(fs.readFileSync(p, 'utf8'));
    if (c && c.dontChroot === true) console.log(`  \x1b[32mok\x1b[0m      ${f} dontChroot: true`);
    else { console.log(`  \x1b[31mFAIL\x1b[0m    ${f} 缺 dontChroot: true（会嵌套 chroot）`); fail++; }
  }
} else {
  console.log('  \x1b[31mFAIL\x1b[0m    找不到 settings.conf');
  fail++;
}

console.log(fail ? `\n\x1b[31m有 ${fail} 处问题\x1b[0m` : '\n\x1b[32mCalamares 配置检查通过\x1b[0m');
process.exit(fail ? 1 : 0);
