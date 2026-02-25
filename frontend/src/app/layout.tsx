import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "TailRisk Agent | ERC-8004 AI Insurance Underwriter",
  description:
    "Autonomous AI agent for on-chain tail-risk insurance. ERC-8004 compliant. Powered by LLM reasoning + Ethereum smart contracts.",
  openGraph: {
    title: "TailRisk Agent",
    description: "ERC-8004 AI-powered tail-risk insurance on Ethereum",
    type: "website",
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className="dark">
      <body className="min-h-screen bg-[#0a0e1a] text-slate-100 antialiased">
        {children}
      </body>
    </html>
  );
}
