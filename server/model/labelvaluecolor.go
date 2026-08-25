// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Steven Fitzpatrick

package model

import "time"

// LabelValueColor is a per-value color override for a label key. The key
// color lives on TagDefinition; a LabelValueColor row overrides it for one
// specific value of that key (e.g. type: meeting gets its own color).
// Rows are scoped like tag definitions: per user, per key.
type LabelValueColor struct {
	UserID int `gorm:"type:int REFERENCES users(id) ON DELETE CASCADE"`
	Key    string
	Value  string
	Color  string
	// UpdatedAtUTC is the server time of the last write (whole seconds),
	// for last-writer-wins sync. Managed explicitly, not by gorm.
	UpdatedAtUTC time.Time
}
