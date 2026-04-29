import { Polar } from "npm:@polar-sh/sdk";

let polar: Polar | null = null;

const chooseServer = (req: Request) =>
  req.headers.get("origin")?.includes("localhost:1337")
    ? "sandbox"
    : "production";

/**
 * Generates Headers with Access-Control-Allow-Origin.
 * If a response is passed in, the headers are cloned
 * and the CORS header set before the Headers are returned.
 */
function corsHeaders(request: Request): Headers {
  const origin = request.headers.get("origin");
  const headers = new Headers();
  const allowedOrigins = [
    "https://nightcore.app",
    "https://nightcore--polar.deno.dev",
    "http://localhost:1337",
  ];

  if (!origin) {
    return new Headers();
  }

  if (allowedOrigins.includes(origin)) {
    headers.set("access-control-allow-origin", origin);
    headers.set("access-control-allow-methods", "GET, OPTIONS");
headers.set("access-control-allow-headers", "content-type");
    headers.set("vary", "origin");
  }

  return headers;
}

function getPolar(req: Request) {
  if (!polar) {
    const { accessToken, server } = getEnvVars(chooseServer(req));

    console.debug(
      `Origin is ${req.headers.get("origin")}, using server: ${server}`,
    );

    polar = new Polar({
      server,
      accessToken,
    });
  } else {
    console.debug("Using cached Polar instance", polar._options);
  }

  return polar;
}

function getEnvVars(server: "production" | "sandbox"): {
  accessToken: string;
  productId: string;
  organizationId: string;
  server: "production" | "sandbox";
} {
  const sandboxEnvVars = [
    "SANDBOX_POLAR_ACCESS_TOKEN",
    "SANDBOX_POLAR_PRODUCT_ID",
    "SANDBOX_POLAR_ORGANIZATION_ID",
  ];

  const productionEnvVars = [
    "POLAR_ACCESS_TOKEN",
    "POLAR_PRODUCT_ID",
    "POLAR_ORGANIZATION_ID",
  ];

  const envVars = server === "sandbox" ? sandboxEnvVars : productionEnvVars;

  for (const varName of envVars) {
    if (!Deno.env.get(varName)) {
      console.error(`Missing environment variable: ${varName}`);
      Deno.exit(1);
    }
  }

  return {
    accessToken: server === "sandbox"
      ? Deno.env.get("SANDBOX_POLAR_ACCESS_TOKEN")!
      : Deno.env.get("POLAR_ACCESS_TOKEN")!,
    productId: server === "sandbox"
      ? Deno.env.get("SANDBOX_POLAR_PRODUCT_ID")!
      : Deno.env.get("POLAR_PRODUCT_ID")!,
    organizationId: server === "sandbox"
      ? Deno.env.get("SANDBOX_POLAR_ORGANIZATION_ID")!
      : Deno.env.get("POLAR_ORGANIZATION_ID")!,
    server,
  };
}

async function checkoutHandler(request: Request) {
  const server = chooseServer(request);
  const { productId } = getEnvVars(server);

  const polar = getPolar(request);

  const checkout = await polar.checkouts.create({
    products: [productId],
  });

  const headers = corsHeaders(request);

  headers.append("content-type", "application/json");

  return new Response(JSON.stringify({ url: checkout.url }), {
    status: 200,
    headers,
  });
}

async function validateKey(key: string, request: Request) : Promise<{
  valid: boolean,
  limitUsage: number | null,
  usage: number | null
}> {
  const polar = getPolar(request);
  const server = chooseServer(request);
  const { organizationId } = getEnvVars(server);

  try {
    const result = await polar.customerPortal.licenseKeys.validate({
      key,
      organizationId,
    });

    const valid = result.status === "granted" && result.limitUsage !== null &&
      result.usage < result.limitUsage;

    return {
      valid,
      limitUsage: result.limitUsage!,
      usage: result.usage,
    };
  } catch (_e) {
    return {
      valid: false,
      limitUsage: null,
      usage: null
    };
  }
}

async function exhaustKey(key: string, request: Request): Promise<boolean> {
  const polar = getPolar(request);
  const server = chooseServer(request);
  const { organizationId } = getEnvVars(server);

  const result = await polar.customerPortal.licenseKeys.validate({
    key,
    organizationId,
    incrementUsage: 1,
  });

  const valid = result.status === "granted" && result.limitUsage !== null &&
    result.usage < result.limitUsage;

  return valid;
}

/**
 * Validate a license key provided by the user.
 * @param request
 * @returns
 */
async function validateHandler(
  request: Request,
) {
  const url = new URL(request.url);
  const key = url.searchParams.get("key");

  if (!key) {
    return new Response("Missing license key", { status: 400 });
  }

  const result = await validateKey(key, request);

  const headers = corsHeaders(request);

  headers.append("content-type", "application/json");

  return new Response(JSON.stringify(result), {
    status: 200,
    headers,
  });
}

/**
 * Use up a license key provided by the user.
 * @param request
 * @returns
 */
async function useHandler(
  request: Request,
) {
  const url = new URL(request.url);
  const key = url.searchParams.get("key");
  const headers = corsHeaders(request);

  headers.append("content-type", "application/json");

  if (!key) {
    return new Response("Missing license key", { status: 400 });
  }

  try {
    const valid = await exhaustKey(key, request);
    return new Response(
      JSON.stringify({ valid }),
      {
        status: 200,
        headers,
      },
    );
  } catch (_e) {
    return new Response(
      JSON.stringify({ message: "Licence key is not valid" }),
      {
        status: 400,
        headers,
      },
    );
  }
}

async function rootHandler(req: Request) {
  return new Response("Welcome to the Nightcore.app Polar service on Deno.");
}

const patternsToHandlers = new Map([
  [{ pathname: "/checkout" }, checkoutHandler],
  [{ pathname: "/validate" }, validateHandler],
  [{ pathname: "/use" }, useHandler],
  [{ pathname: "/validate/:key" }, validateHandler],
  [{ pathname: "/" }, rootHandler],
]);

const routingMap: Map<URLPattern, (request: Request) => Promise<Response>> =
  new Map();

for (const [patternInput, handler] of patternsToHandlers) {
  const compiledPattern = new URLPattern(patternInput);
  routingMap.set(compiledPattern, handler);
}

Deno.serve((request: Request) => {
  if (request.method.toUpperCase() === "OPTIONS") {
    return new Response(null, { headers: corsHeaders(request) });
  }

  for (const [compiledPattern, handler] of routingMap) {
    const result = compiledPattern.exec(request.url);
    if (result) {
      return handler(request);
    }
  }

  return new Response("Not found", { status: 404 });
});
