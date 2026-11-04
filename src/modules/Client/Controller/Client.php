<?php

declare(strict_types=1);
/**
 * Copyright 2022-2025 FOSSBilling
 * SPDX-License-Identifier: Apache-2.0.
 *
 * @copyright FOSSBilling (https://www.fossbilling.org)
 * @license http://www.apache.org/licenses/LICENSE-2.0 Apache-2.0
 */

namespace Box\Mod\Client\Controller;

use FOSSBilling\Security\RandomizedTimeFloor;
use Symfony\Component\HttpFoundation\Response;

class Client implements \FOSSBilling\InjectionAwareInterface
{
    protected ?\Pimple\Container $di = null;

    public function setDi(\Pimple\Container $di): void
    {
        $this->di = $di;
    }

    public function getDi(): ?\Pimple\Container
    {
        return $this->di;
    }

    public function register(\Box_App &$app): void
    {
        $app->get('/checkout', 'get_checkout', [], static::class);
        $app->get('/client/reset-password-confirm/:hash', 'get_reset_password_confirm', ['hash' => '[a-z0-9]+'], static::class);
        $app->get('/client', 'get_client_index', [], static::class);
        $app->get('/client/logout', 'get_client_logout', [], static::class);
        $app->get('/client/:page', 'get_client_page', ['page' => '[a-z0-9-]+'], static::class);
        $app->get('/client/confirm-email/:hash', 'get_client_confirmation', ['page' => '[a-z0-9-]+'], static::class);
    }

    /**
     * WordPress → FOSSBilling SSO handoff.
     *
     * Validates the signed wp_token issued by udp-billing-bridge.php, then
     * finds or auto-creates the FOSSBilling client record and establishes a
     * session. The optional ?plan= param is a product slug; if present the
     * customer is sent directly to that product's order page.
     */
    public function get_checkout(\Box_App $app): Response
    {
        $token = $_GET['wp_token'] ?? '';
        $plan  = preg_replace('/[^a-z0-9-]/', '', strtolower($_GET['plan']  ?? ''));
        $promo = preg_replace('/[^A-Z0-9_]/', '', strtoupper($_GET['promo'] ?? ''));

        if (!$token) {
            return $app->redirect('/login');
        }

        $service = $this->di['mod_service']('Client');

        try {
            $client = $service->loginClientFromWpToken($token);
        } catch (\Exception $e) {
            $this->di['mod_service']('System')->setPendingMessage($e->getMessage());

            return $app->redirect('/login');
        }

        $oldSession = $this->di['session']->getId();
        $this->di['session']->regenerateId();
        $this->di['session']->set('client_id', $client->getId());
        $this->di['mod_service']('cart')->transferFromOtherSession($oldSession);

        $this->di['logger']->info('Client #%s logged in via WP token', $client->getId());

        $redirect = $plan ? '/order/' . $plan : '/order';
        if ($promo !== '') {
            $redirect .= '?promocode=' . urlencode($promo);
        }

        return $app->redirect($redirect);
    }

    public function get_client_index(\Box_App $app): string
    {
        $this->di['is_client_logged'];

        return $app->render('mod_client_index');
    }

    public function get_client_confirmation(\Box_App $app, $hash): string|Response
    {
        if ($error = $this->checkPageRateLimit($app, 'client_email_confirm_ip')) {
            return $error;
        }

        $startedAt = microtime(true);
        $service = $this->di['mod_service']('client');

        try {
            $service->approveClientEmailByHash($hash);
        } finally {
            RandomizedTimeFloor::apply($startedAt);
        }

        $systemService = $this->di['mod_service']('System');
        $systemService->setPendingMessage(__trans('Email address was confirmed'));

        return $app->redirect('/');
    }

    public function get_client_logout(\Box_App $app): Response
    {
        $api = $this->di['api_client'];
        $api->profile_logout();

        return $app->redirect('/');
    }

    public function get_client_page(\Box_App $app, $page): string
    {
        $this->di['is_client_logged'];
        $template = 'mod_client_' . $page;

        return $app->render($template);
    }

    public function get_reset_password_confirm(\Box_App $app, $hash): string|Response
    {
        if ($error = $this->checkPageRateLimit($app, 'client_password_reset_confirm_ip')) {
            return $error;
        }

        $service = $this->di['mod_service']('client');
        $this->di['events_manager']->fire(['event' => 'onBeforePasswordResetClient']);
        $data = [
            'hash' => $hash,
        ];

        $startedAt = microtime(true);

        try {
            $result = $service->password_reset_valid($data);
        } finally {
            RandomizedTimeFloor::apply($startedAt);
        }

        if ($result !== false) {
            return $app->render('mod_client_set_new_password', ['hash' => $hash]);
        }

        return $app->redirect('/');
    }

    private function checkPageRateLimit(\Box_App $app, string $policy): ?Response
    {
        $result = $this->di['rate_limiter']->consume($policy, (string) $this->di['request']->getClientIp());
        if (!$result->isLimited()) {
            return null;
        }

        $headers = [];
        if ($result->hasRetryAfter()) {
            $headers['Retry-After'] = (string) $result->getRetryAfterSeconds();
        }

        return $app->errorResponse(new \FOSSBilling\Security\RateLimitException($result), 429, $headers);
    }
}
