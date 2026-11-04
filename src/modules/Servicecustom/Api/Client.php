<?php

/**
 * Copyright 2022-2025 FOSSBilling
 * Copyright 2011-2021 BoxBilling, Inc.
 * SPDX-License-Identifier: Apache-2.0.
 *
 * @copyright FOSSBilling (https://www.fossbilling.org)
 * @license http://www.apache.org/licenses/LICENSE-2.0 Apache-2.0
 */

namespace Box\Mod\Servicecustom\Api;

/**
 * Custom product management.
 */
class Client extends \Api_Abstract
{
    /**
     * Return the current provisioning status for a Standard-tier order by
     * proxying to the orchestrator's GET /slots/{slot_id} endpoint.
     *
     * Does not require the orchestrator API key — the status endpoint is public.
     *
     * @param array $data Must contain 'order_id'
     * @return array{status: string, instance_url: string|null, error: string|null}
     */
    public function get_slot_status(array $data): array
    {
        if (empty($data['order_id'])) {
            throw new \FOSSBilling\Exception('order_id is required');
        }
        $orderId = (int) $data['order_id'];

        // Verify the order belongs to the authenticated client
        $order = $this->di['db']->findOne(
            'ClientOrder',
            'id = ? AND client_id = ?',
            [$orderId, $this->identity->id]
        );
        if (!$order) {
            throw new \FOSSBilling\Exception('Order not found', null, 404);
        }

        try {
            $model = $this->getService()->getServiceCustomByOrderId($orderId);
        } catch (\Exception $e) {
            return ['status' => 'PENDING', 'instance_url' => null, 'error' => null];
        }

        $config = json_decode($model->config ?? '', true) ?? [];
        $slotId = $config['slot_id'] ?? '';

        if ($slotId === '') {
            return ['status' => 'PENDING', 'instance_url' => null, 'error' => null];
        }

        $ch = curl_init('http://localhost:8000/slots/' . rawurlencode($slotId));
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT        => 5,
            CURLOPT_CONNECTTIMEOUT => 3,
        ]);
        $response = curl_exec($ch);
        $httpCode  = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $curlErr   = curl_error($ch);
        curl_close($ch);

        if ($curlErr !== '' || $httpCode !== 200 || $response === false) {
            return ['status' => 'PENDING', 'instance_url' => null, 'error' => null];
        }

        $body = json_decode($response, true) ?? [];
        return [
            'status'       => $body['status']       ?? 'PENDING',
            'instance_url' => $body['instance_url'] ?? null,
            'error'        => $body['error']         ?? null,
        ];
    }

    /**
     * Universal method to call method from plugin
     * Pass any other params and they will be passed to plugin.
     *
     * @throws \FOSSBilling\Exception
     */
    public function __call($name, $arguments)
    {
        if (!isset($arguments[0])) {
            throw new \FOSSBilling\Exception('API call is missing arguments', null, 7103);
        }

        $data = $arguments[0];

        if (!isset($data['order_id'])) {
            throw new \FOSSBilling\Exception('Order ID is required');
        }
        $model = $this->getService()->getServiceCustomByOrderId($data['order_id']);

        return $this->getService()->customCall($model, $name, $data);
    }
}
