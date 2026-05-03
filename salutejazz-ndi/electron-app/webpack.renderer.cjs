const path = require('path');
const HtmlWebpackPlugin = require('html-webpack-plugin');

module.exports = {
  target: 'electron-renderer',
  entry: {
    renderer: path.resolve(__dirname, 'src/renderer.ts'),
  },
  output: {
    path: path.resolve(__dirname, 'dist/renderer'),
    filename: '[name].js',
  },
  resolve: {
    extensions: ['.ts', '.tsx', '.js'],
  },
  module: {
    rules: [
      {
        test: /\.tsx?$/,
        use: {
          loader: 'ts-loader',
          options: {
            configFile: path.resolve(__dirname, 'tsconfig.renderer.json'),
          },
        },
        exclude: /node_modules/,
      },
    ],
  },
  // Don't bundle the native NDI bridge — it must be loaded at runtime via require.
  externals: {
    'salutejazz-ndi-bridge': 'commonjs2 salutejazz-ndi-bridge',
  },
  plugins: [
    new HtmlWebpackPlugin({
      template: path.resolve(__dirname, 'src/index.html'),
      filename: 'index.html',
    }),
  ],
  devtool: 'source-map',
};
