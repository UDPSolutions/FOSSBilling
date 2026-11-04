<?php

/**
 * UDP Social — Servicecustom Guest API
 * SPDX-License-Identifier: Apache-2.0
 */

namespace Box\Mod\Servicecustom\Api;

/**
 * Guest-accessible endpoints for the custom service module.
 */
class Guest extends \Api_Abstract
{
    /**
     * Check whether a udp.social subdomain label is available.
     *
     * Considers:
     *  - Active orders holding the label
     *  - Orders in grace period (canceled but not yet expired)
     *
     * @param array $data  Must contain 'subdomain' — the label only, e.g. "smith" for smith.udp.social
     *
     * @return array{available: bool, reason?: string}
     */
    public function check_subdomain(array $data): array
    {
        $label = trim(strtolower($data['subdomain'] ?? ''));

        if ($label === '') {
            throw new \FOSSBilling\InformationException('Subdomain label is required');
        }

        if (!preg_match('/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/', $label)) {
            return ['available' => false, 'reason' => 'invalid'];
        }

        if ($this->isSubdomainClaimed($label)) {
            return ['available' => false, 'reason' => 'taken'];
        }

        return ['available' => true];
    }

    /**
     * Query service_custom config JSON for any active or grace-period claim on the label.
     */
    private function isSubdomainClaimed(string $label): bool
    {
        // Search service_custom rows where config contains this subdomain.
        // We filter to non-deleted orders (active, suspended, or canceled-within-grace-period).
        // Grace period expiry is stored in the config as 'grace_period_ends_at'.
        $rows = $this->di['db']->getAll(
            "SELECT sc.config
               FROM service_custom sc
               JOIN client_order co ON co.id = (
                   SELECT id FROM client_order
                   WHERE service_type = 'custom'
                     AND service_id = sc.id
                   LIMIT 1
               )
              WHERE co.status IN ('active', 'suspended', 'canceled')
                AND sc.config LIKE :pattern",
            [':pattern' => '%"subdomain":"' . $label . '"%']
        );

        foreach ($rows as $row) {
            $config = json_decode($row['config'] ?? '', true) ?? [];

            if (($config['subdomain'] ?? '') !== $label) {
                continue; // LIKE match was a false positive
            }

            if (($config['domain_type'] ?? '') !== 'subdomain') {
                continue; // label is stored but not in subdomain mode
            }

            // Canceled orders are only a hold if still within grace period
            if (isset($config['grace_period_ends_at'])) {
                if (strtotime($config['grace_period_ends_at']) > time()) {
                    return true;
                }
                continue; // grace period has expired — label is free
            }

            // Active or suspended with no grace period end set — definitely claimed
            return true;
        }

        return false;
    }
}
