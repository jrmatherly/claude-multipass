/**
 * @see https://prettier.io/docs/en/options
 * @type {import("prettier").Config}
 */
const config = {
  singleQuote: true,
  semi: false,
  trailingComma: 'es5',
  plugins: ['prettier-plugin-sh'],
  overrides: [
    {
      files: '*.md',
      options: {
        arrowParens: 'avoid',
        printWidth: 70,
        proseWrap: 'never',
        trailingComma: 'none',
      },
    },
  ],
}

module.exports = config
