// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Steven Fitzpatrick

// Package preference implements Moment Tally v1 user preferences: the small
// set of per-user client state a second device should inherit (coloring
// data itself syncs via label definitions).
package preference

import (
	"context"
	"time"

	"github.com/jinzhu/gorm"
	"momenttally.com/server/auth"
	"momenttally.com/server/generated/gqlmodel"
	"momenttally.com/server/model"
)

// syncNow is the clock for sync timestamps (UpdatedAtUTC): whole seconds so
// values round-trip through RFC3339 exactly. Overridable in tests.
var syncNow = func() time.Time { return time.Now().UTC().Truncate(time.Second) }

// ResolverForPreferences resolves user preference things.
type ResolverForPreferences struct {
	DB *gorm.DB
}

// UserPreferences returns the current user's preferences, or the defaults
// if they have never been set.
func (r *ResolverForPreferences) UserPreferences(ctx context.Context) (*gqlmodel.UserPreferences, error) {
	userID := auth.GetUser(ctx).ID

	preferences := model.UserPreferences{}
	find := r.DB.Where(&model.UserPreferences{UserID: userID}).Find(&preferences)
	if find.RecordNotFound() {
		preferences = model.DefaultUserPreferences(userID)
	} else if find.Error != nil {
		return nil, find.Error
	}

	return toExternal(preferences), nil
}

// SetUserPreferences replaces the current user's preferences.
func (r *ResolverForPreferences) SetUserPreferences(ctx context.Context, input gqlmodel.InputUserPreferences) (*gqlmodel.UserPreferences, error) {
	userID := auth.GetUser(ctx).ID

	preferences := model.UserPreferences{
		UserID:            userID,
		ColorByValue:      input.ColorByValue,
		MenuLabelSetLimit: input.MenuLabelSetLimit,
		UpdatedAtUTC:      syncNow(),
	}

	existing := model.UserPreferences{}
	if r.DB.Where(&model.UserPreferences{UserID: userID}).Find(&existing).RecordNotFound() {
		if err := r.DB.Create(&preferences).Error; err != nil {
			return nil, err
		}
	} else {
		if err := r.DB.Model(new(model.UserPreferences)).
			Where("user_id = ?", userID).
			Updates(map[string]interface{}{
				"color_by_value":       input.ColorByValue,
				"menu_label_set_limit": input.MenuLabelSetLimit,
				"updated_at_utc":       preferences.UpdatedAtUTC,
			}).Error; err != nil {
			return nil, err
		}
	}

	return toExternal(preferences), nil
}

func toExternal(preferences model.UserPreferences) *gqlmodel.UserPreferences {
	return &gqlmodel.UserPreferences{
		ColorByValue:      preferences.ColorByValue,
		MenuLabelSetLimit: preferences.MenuLabelSetLimit,
		UpdatedAt:         model.Time(preferences.UpdatedAtUTC),
	}
}
