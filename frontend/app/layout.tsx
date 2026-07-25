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
  const socialImage = new URL("/og-factoring.png", origin).toString();

  return {
    metadataBase: new URL(origin),
    title: "Impatience — Onchain factoring",
    description:
      "Sell future withdrawal and redemption payouts for liquidity today.",
    icons: {
      icon: "/favicon.svg",
    },
    openGraph: {
      title: "Impatience — Onchain factoring",
      description:
        "Sell future protocol payouts. Get paid now.",
      type: "website",
      images: [
        {
          url: socialImage,
          width: 1200,
          height: 630,
          alt: "Impatience onchain factoring markets for delayed withdrawal claims.",
        },
      ],
    },
    twitter: {
      card: "summary_large_image",
      title: "Impatience — Onchain factoring",
      description:
        "Sell future protocol payouts. Get paid now.",
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
