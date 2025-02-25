import { Polar } from "npm:@polar-sh/sdk";

function checkoutHandler (request: Request) {
    const polar = new Polar({
        accessToken: Deno.env.get("POLAR_ACCESS_TOKEN") ?? "",
    });

    const checkout = await polar.checkouts.create({
        productId: "3155f5e1-3730-44b4-a28d-8a3d5752f1fe",
    });

    return new Response(null, {
        status: 302,
        headers: {
            'Location': checkout.url
        }
    })
}

function verifyHandler (request: Request) {
    return new Response('Not yet implemented', { status: 404 });
}


function rootHandler (req: Request) {
    return new Response('Welcome to the Nightcore.app Polar service on Deno.');
}

const patternsToHandlers = new Map([
  [{pathname: '/checkout'}, pageHandler],
  [{pathname: '/verify'}, verifyHandler],
  [{pathname: '/'}, rootHandler],
]);

const routingMap = new Map();

for (const [patternInput, handler] of patternsToHandlers) {
  const compiledPattern = new URLPattern(patternInput);
  routingMap.set(compiledPattern, handler);
}

Deno.serve((request: Request) => {
    for (const [compiledPattern, handler] of routingMap) {
        const result = compiledPattern.exec(request.url);
        if (result) {
            return handler(result);
        }
  }
});
