import ts from 'typescript';
import { createHash } from 'node:crypto';
import { isBuiltin } from 'node:module';
import { createTranslator } from './engine.mjs';

export const translate = createTranslator({
    ts,
    sha256: value => createHash('sha256').update(value).digest('hex'),
    utf8Size: value => Buffer.byteLength(value),
    isBuiltin
});
