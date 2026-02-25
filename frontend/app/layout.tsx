import type { Metadata } from "next";
import type { ReactNode } from "react";

export const metadata: Metadata = {
  title: "ERC-8004 Tail-Risk Protection Agent",
  description: "Pre-build dashboard scaffold for ERC-8004 AI trading agents",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
