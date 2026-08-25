// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Steven Fitzpatrick

// Value colors: per-value color overrides for a label key (Moment Tally v1).
// The key color lives on the label definition; these mutations manage the
// LabelValueColor rows layered on top of it.

package tag

import (
	"context"
	"fmt"

	"github.com/jinzhu/gorm"
	"momenttally.com/server/auth"
	"momenttally.com/server/generated/gqlmodel"
	"momenttally.com/server/model"
)

// SetLabelValueColor sets (or replaces) the color override for one value of
// a label key and returns the updated definition.
func (r *ResolverForTag) SetLabelValueColor(ctx context.Context, key string, value string, color string) (*gqlmodel.LabelDefinition, error) {
	userID := auth.GetUser(ctx).ID
	if r.DB.Where(&model.TagDefinition{UserID: userID, Key: key}).Find(new(model.TagDefinition)).RecordNotFound() {
		return nil, fmt.Errorf("label definition with key '%s' does not exist", key)
	}

	existing := model.LabelValueColor{}
	notFound := r.DB.
		Where("user_id = ? AND key = ? AND value = ?", userID, key, value).
		Find(&existing).RecordNotFound()
	if notFound {
		row := model.LabelValueColor{
			UserID: userID, Key: key, Value: value, Color: color,
			UpdatedAtUTC: syncNow(),
		}
		if err := r.DB.Create(&row).Error; err != nil {
			return nil, err
		}
	} else {
		if err := r.DB.Model(new(model.LabelValueColor)).
			Where("user_id = ? AND key = ? AND value = ?", userID, key, value).
			Updates(map[string]interface{}{
				"color":          color,
				"updated_at_utc": syncNow(),
			}).Error; err != nil {
			return nil, err
		}
	}

	return labelDefinition(r.DB, userID, key)
}

// ClearLabelValueColor removes the color override for one value of a label
// key (the value falls back to the key color) and returns the updated
// definition.
func (r *ResolverForTag) ClearLabelValueColor(ctx context.Context, key string, value string) (*gqlmodel.LabelDefinition, error) {
	userID := auth.GetUser(ctx).ID
	if r.DB.Where(&model.TagDefinition{UserID: userID, Key: key}).Find(new(model.TagDefinition)).RecordNotFound() {
		return nil, fmt.Errorf("label definition with key '%s' does not exist", key)
	}

	if err := r.DB.
		Where("user_id = ? AND key = ? AND value = ?", userID, key, value).
		Delete(new(model.LabelValueColor)).Error; err != nil {
		return nil, err
	}

	return labelDefinition(r.DB, userID, key)
}

// labelDefinition loads a single definition (with usages and value colors)
// in its external form.
func labelDefinition(db *gorm.DB, userID int, key string) (*gqlmodel.LabelDefinition, error) {
	definition := model.TagDefinition{}
	if err := db.Where(&model.TagDefinition{UserID: userID, Key: key}).Find(&definition).Error; err != nil {
		return nil, err
	}

	usages := 0
	if err := db.Model(new(model.TimeSpanTag)).
		Joins("JOIN time_spans ON time_spans.id = time_span_tags.time_span_id").
		Where("time_spans.user_id = ?", userID).
		Where("time_span_tags.key = ?", key).
		Count(&usages).Error; err != nil {
		return nil, err
	}

	colors, err := valueColors(db, userID, key)
	if err != nil {
		return nil, err
	}

	return &gqlmodel.LabelDefinition{
		Key:         definition.Key,
		Color:       definition.Color,
		Usages:      usages,
		ValueColors: colors,
		UpdatedAt:   model.Time(definition.UpdatedAtUTC),
	}, nil
}

// valueColors loads the value color overrides of one key in external form.
func valueColors(db *gorm.DB, userID int, key string) ([]*gqlmodel.LabelValueColor, error) {
	var rows []model.LabelValueColor
	if err := db.
		Where("user_id = ? AND key = ?", userID, key).
		Order("value").
		Find(&rows).Error; err != nil {
		return nil, err
	}
	result := []*gqlmodel.LabelValueColor{}
	for _, row := range rows {
		result = append(result, &gqlmodel.LabelValueColor{
			Value: row.Value, Color: row.Color,
			UpdatedAt: model.Time(row.UpdatedAtUTC),
		})
	}
	return result, nil
}

// valueColorsByKey loads all value color overrides of a user grouped by key.
func valueColorsByKey(db *gorm.DB, userID int) (map[string][]*gqlmodel.LabelValueColor, error) {
	var rows []model.LabelValueColor
	if err := db.
		Where("user_id = ?", userID).
		Order("key, value").
		Find(&rows).Error; err != nil {
		return nil, err
	}
	result := map[string][]*gqlmodel.LabelValueColor{}
	for _, row := range rows {
		result[row.Key] = append(result[row.Key], &gqlmodel.LabelValueColor{
			Value: row.Value, Color: row.Color,
			UpdatedAt: model.Time(row.UpdatedAtUTC),
		})
	}
	return result, nil
}
