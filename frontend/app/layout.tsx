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
  const socialImage = new URL("/og-live-v2.png", origin).toString();

  return {
    metadataBase: new URL(origin),
    title: "Reservoir — Instant liquidity for asynchronous claims",
    description:
      "Replay the verified Lido/Aave fork proof, inspect canonical Lido claims, or atomically exchange a signed claim for productive reserve-backed WETH.",
    icons: {
      icon: "/favicon.svg",
    },
    openGraph: {
      title: "Reservoir — The claim moves before the money does.",
      description:
        "A verified ETHGlobal jury proof and wallet-ready Lido interface for productive reserve-backed claim settlement.",
      type: "website",
      images: [
        {
          url: socialImage,
          width: 1200,
          height: 630,
          alt: "Reservoir acquires an asynchronous withdrawal claim before paying exact WETH.",
        },
      ],
    },
    twitter: {
      card: "summary_large_image",
      title: "Reservoir — Instant liquidity for asynchronous claims",
      description:
        "Acquire the claim first. Materialize exact WETH second.",
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
