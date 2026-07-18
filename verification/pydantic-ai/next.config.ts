import type { NextConfig } from "next";

// Swap B (ag-ui verification): when RUBY_RUNTIME_URL is set, proxy the whole
// CopilotKit surface straight to the Ruby server — no Node runtime in the
// path. Run scripts/swap-b.sh first (it parks the Node runtime API route;
// app routes always win over rewrites).
const rubyRuntime = process.env.RUBY_RUNTIME_URL;

const nextConfig: NextConfig = {
  output: "standalone",
  serverExternalPackages: ["@copilotkit/runtime"],
  ...(rubyRuntime
    ? {
        rewrites: async () => [
          {
            source: "/api/copilotkit/:path*",
            destination: `${rubyRuntime}/api/copilotkit/:path*`,
          },
        ],
      }
    : {}),
  typescript: {
    // @ag-ui/client's HttpAgent currently exposes private generic types through
    // the runtime route in this example. Keep builds focused on runtime output.
    ignoreBuildErrors: true,
  },
};

export default nextConfig;
