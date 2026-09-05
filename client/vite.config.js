import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

/**
 * Builds the wizard into the engine's public/wizard/ with stable file names,
 * so the engine's ERB page can reference them without reading a manifest, and
 * the built files can be committed and served by the engine with no Node step
 * on the host.
 *
 * `base` matches the path the engine serves the directory at.
 */
export default defineConfig({
  base: '/wizard/',
  plugins: [react()],
  build: {
    outDir: '../public/wizard',
    emptyOutDir: true,
    rollupOptions: {
      output: {
        entryFileNames: 'assets/wizard.js',
        chunkFileNames: 'assets/[name].js',
        assetFileNames: (info) => (
          info.name?.endsWith('.css') ? 'assets/wizard.css' : 'assets/[name][extname]'
        )
      }
    }
  },
  server: {
    port: 5175,
    proxy: {
      // The engine's API on the local host app.
      '/core_data': 'http://localhost:3001'
    }
  }
});
