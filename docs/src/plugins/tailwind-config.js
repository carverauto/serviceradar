/**
 * Inject Tailwind CSS v4 into Docusaurus's PostCSS pipeline.
 *
 * We intentionally do not enable global Preflight — Infima owns base element
 * styles. Use Tailwind utilities + @theme tokens for custom UI.
 */
module.exports = function tailwindPlugin() {
  return {
    name: 'tailwind-plugin',
    configurePostCss(postcssOptions) {
      postcssOptions.plugins.push(require('@tailwindcss/postcss'));
      return postcssOptions;
    },
  };
};
