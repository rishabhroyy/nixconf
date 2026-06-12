<?php

namespace Pterodactyl\Http\Middleware;

use Closure;
use Ramsey\Uuid\Uuid;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Str;
use Pterodactyl\Models\User;

class AuthentikSso
{
    public function handle(Request $request, Closure $next)
    {
        $expected = (string) env('PYRODACTYL_SSO_SECRET', '');
        $provided = (string) $request->header('X-Pyrodactyl-Sso-Secret', '');
        $username = strtolower((string) $request->header('X-Authentik-Username', ''));
        $email = strtolower((string) $request->header('X-Authentik-Email', ''));

        if ($expected === '' || !hash_equals($expected, $provided) || $username === '' || !filter_var($email, FILTER_VALIDATE_EMAIL)) {
            return $next($request);
        }

        $username = preg_replace('/[^a-z0-9_.-]/', '-', $username);
        $externalId = 'authentik:' . ((string) $request->header('X-Authentik-Uid', $username));
        $name = trim((string) $request->header('X-Authentik-Name', $username));
        $parts = preg_split('/\s+/', $name, 2);

        $user = User::query()
            ->where('external_id', $externalId)
            ->orWhere('email', $email)
            ->first();

        if (!$user) {
            $user = User::query()->create([
                'uuid' => Uuid::uuid4()->toString(),
                'external_id' => $externalId,
                'username' => $username,
                'email' => $email,
                'name_first' => $parts[0] ?: $username,
                'name_last' => $parts[1] ?? null,
                'password' => Hash::make(Str::random(64)),
                'root_admin' => $username === 'akadmin',
                'language' => 'en',
                'use_totp' => false,
            ]);
        } elseif (!$user->external_id) {
            $user->external_id = $externalId;
            $user->save();
        }

        if ($username === 'akadmin' && !$user->root_admin) {
            $user->root_admin = true;
            $user->save();
        }

        if (!Auth::guard()->check() || Auth::guard()->id() !== $user->id) {
            Auth::guard()->login($user, true);
        }

        return $next($request);
    }
}
