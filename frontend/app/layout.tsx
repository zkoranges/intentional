import type { Metadata } from "next";
import { headers } from "next/headers";
import "./globals.css";

export async function generateMetadata(): Promise<Metadata> {
  const requestHeaders = await headers();
  const host = (
    requestHeaders.get("x-forwarded-host") ??
    requestHeaders.get("host") ??
    "localhost:3000"
  )
    .split(",")[0]
    .trim();
  const protocol =
    requestHeaders.get("x-forwarded-proto") ??
    (host.startsWith("localhost") || host.startsWith("127.0.0.1")
      ? "http"
      : "https");
  const origin = `${protocol}://${host}`;
  const socialImage = new URL("/og.png", origin).toString();

  return {
    metadataBase: new URL(origin),
    title: "Reservoir — Make waiting optional",
    description:
      "Instant liquidity for delayed withdrawals, with a direct Lido queue route when you prefer to keep the claim.",
    icons: {
      icon: "/favicon.svg",
    },
    openGraph: {
      title: "Reservoir — Make waiting optional.",
      description:
        "Exchange a delayed withdrawal for immediate liquidity, or enter the Lido queue directly.",
      type: "website",
      images: [
        {
          url: socialImage,
          width: 1200,
          height: 630,
          alt: "Reservoir instant exit interface showing stETH exchanged for WETH.",
        },
      ],
    },
    twitter: {
      card: "summary_large_image",
      title: "Reservoir — Make waiting optional.",
      description:
        "Liquidity for delayed withdrawals.",
      images: [socialImage],
    },
  };
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
