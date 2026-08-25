// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Steven Fitzpatrick

package model

import "time"

// UserPreferences is the per-user client state a second device should
// inherit. Coloring *data* (key and value colors) already syncs via label
// definitions; these are the remaining bits. Absence of a row means the
// defaults apply (see DefaultUserPreferences).
type UserPreferences struct {
	UserID int `gorm:"primary_key;unique_index"`
	// ColorByValue colors timespans by label value (Moment Tally's default
	// behaviour); key colors remain for navigating Label Review.
	ColorByValue bool
	// MenuLabelSetLimit is how many label sets the menu shows (0 = all).
	MenuLabelSetLimit int
	// UpdatedAtUTC is the server time of the last write (whole seconds),
	// for last-writer-wins sync; the zero value means "never written" and
	// loses to any device's local edit. Managed explicitly, not by gorm.
	UpdatedAtUTC time.Time
}

// DefaultUserPreferences returns the preferences of a fresh user.
func DefaultUserPreferences(userID int) UserPreferences {
	return UserPreferences{
		UserID:            userID,
		ColorByValue:      true,
		MenuLabelSetLimit: 5,
	}
}
