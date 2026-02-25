import type { Config } from "tailwindcss";

const config: Config = {
  content: [
    "./src/pages/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/components/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/app/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      colors: {
        brand: {
          50: "#f0f4ff",
          100: "#dde6ff",
          200: "#c3d1ff",
          300: "#9ab4ff",
          400: "#698cff",
          500: "#4060ff",
          600: "#2a3ff5",
          700: "#2232e1",
          800: "#1f2cb6",
          900: "#1e2a8f",
          950: "#131a5c",
        },
        danger: {
          400: "#f87171",
          500: "#ef4444",
          600: "#dc2626",
        },
        warn: {
          400: "#fbbf24",
          500: "#f59e0b",
        },
        success: {
          400: "#34d399",
          500: "#10b981",
        },
      },
      fontFamily: {
        mono: ["JetBrains Mono", "Fira Code", "monospace"],
      },
      animation: {
        "pulse-slow": "pulse 3s cubic-bezier(0.4, 0, 0.6, 1) infinite",
        "spin-slow": "spin 3s linear infinite",
      },
    },
  },
  plugins: [],
};

export default config;
