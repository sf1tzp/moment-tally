// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Steven Fitzpatrick

package labelset

import (
	"github.com/jinzhu/gorm"
	"momenttally.com/server/model"
)

// DefaultLabelColor is the color given to label definitions created while
// seeding a user with the default collection.
const DefaultLabelColor = "#2196f3"

// SeedDefaultLabelSets copies the default collection (template label sets
// with a nil user and the default-collection flag) to the given user, and
// creates a label definition for every referenced key the user does not have
// yet. It is called for newly created users; calling it again is safe but
// will duplicate sets, so callers seed exactly once (or use the admin CLI's
// seed-user on a user they know is unseeded).
func SeedDefaultLabelSets(db *gorm.DB, userID int) error {
	var templates []model.LabelSet
	if err := preloadMembers(db).
		Where("user_id IS NULL AND default_collection = ?", true).
		Order("position").
		Find(&templates).Error; err != nil {
		return err
	}

	for i, template := range templates {
		set := model.LabelSet{
			UserID:       &userID,
			Name:         template.Name,
			SymbolName:   template.SymbolName,
			Position:     i,
			UpdatedAtUTC: syncNow(),
		}
		for _, member := range template.Members {
			set.Members = append(set.Members, model.LabelSetMember{
				Position:    member.Position,
				Key:         member.Key,
				StringValue: member.StringValue,
				Quick:       member.Quick,
			})
		}
		if err := db.Create(&set).Error; err != nil {
			return err
		}

		for _, member := range template.Members {
			if !db.Where("user_id = ? AND key = ?", userID, member.Key).
				Find(new(model.TagDefinition)).RecordNotFound() {
				continue
			}
			definition := model.TagDefinition{
				UserID:       userID,
				Key:          member.Key,
				Color:        DefaultLabelColor,
				UpdatedAtUTC: syncNow(),
			}
			if err := db.Create(&definition).Error; err != nil {
				return err
			}
		}
	}
	return nil
}
