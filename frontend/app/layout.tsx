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
    title: "Impatience — Get paid now",
    description:
      "Sell the right to a delayed withdrawal for liquidity now, or keep the claim and wait.",
    icons: {
      icon: "/favicon.svg",
    },
    openGraph: {
      title: "Impatience — Get paid now.",
      description:
        "Sell the right to a delayed withdrawal. Someone else waits.",
      type: "website",
      images: [
        {
          url: socialImage,
          width: 1200,
          height: 630,
          alt: "Impatience instant exit interface comparing liquidity now with waiting.",
        },
      ],
    },
    twitter: {
      card: "summary_large_image",
      title: "Impatience — Get paid now.",
      description:
        "Sell the right to a delayed withdrawal. Someone else waits.",
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
