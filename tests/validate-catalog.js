'use strict';
const fs = require('fs');
const path = require('path');
const Ajv2020 = require('ajv/dist/2020');
const addFormats = require('ajv-formats');

const root = path.resolve(__dirname, '..');
const schema = JSON.parse(fs.readFileSync(path.join(root, 'catalog', 'schema.json'), 'utf8'));
const catalog = JSON.parse(fs.readFileSync(path.join(root, 'catalog', 'catalog.json'), 'utf8'));
const ajv = new Ajv2020({ allErrors: true, strict: true });
addFormats(ajv);
const validate = ajv.compile(schema);
if (!validate(catalog)) {
  console.error(ajv.errorsText(validate.errors, { separator: '\n' }));
  process.exit(1);
}
console.log(`Catalog ${catalog.catalogVersion} is valid (${catalog.mods.length} records).`);
